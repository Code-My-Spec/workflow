defmodule Workflow.LoopAnswersSupportTest do
  # Not async: the manager, its run and the environment are the whole application's.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir
  @topic "loop:p1"

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    keys = [:manager, :works_dir, :alloy_run, :manager_run]
    was = for key <- keys, do: {key, Application.fetch_env(:workflow, key)}
    harness = System.get_env("CMS_HARNESS_ID")
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    on_exit(fn ->
      Workflow.Tellings.quiet()

      for {key, value} <- was do
        case value do
          {:ok, value} -> Application.put_env(:workflow, key, value)
          :error -> Application.delete_env(:workflow, key)
        end
      end

      if harness,
        do: System.put_env("CMS_HARNESS_ID", harness),
        else: System.delete_env("CMS_HARNESS_ID")
    end)
  end

  # A fake channel process: every push is told to the test, with the ref it is answered with.
  defp fake_channel do
    test = self()

    spawn_link(fn ->
      Stream.repeatedly(fn ->
        receive do
          {:"$gen_call", from, {_, %Slipstream.Commands.PushMessage{} = push}} ->
            ref = make_ref()
            send(test, {:pushed, push.event, push.payload, ref})
            # As the connection does: the push's ref, which its reply comes back under.
            GenServer.reply(from, ref)

          _other ->
            :ok
        end
      end)
      |> Stream.run()
    end)
  end

  defp socket(joined? \\ true) do
    socket =
      %{
        Slipstream.Socket.new()
        | channel_pid: fake_channel(),
          channel_config:
            Slipstream.Configuration.validate!(uri: "ws://localhost/socket/websocket")
      }
      |> Slipstream.Socket.assign(topic: @topic, server: %{}, started: true)

    if joined? do
      join = %Slipstream.Socket.Join{
        topic: @topic,
        params: %{},
        status: :joined,
        rejoin_counter: 0
      }

      put_in(socket.joins[@topic], join)
    else
      socket
    end
  end

  test "loop-answers-support: the join carries harness_id when CMS_HARNESS_ID is set, and none when not" do
    System.put_env("CMS_HARNESS_ID", "harness-7")
    {:ok, socket} = Workflow.Server.handle_connect(socket(false))
    assert socket.joins[@topic].params == %{"harness_id" => "harness-7"}

    System.delete_env("CMS_HARNESS_ID")
    {:ok, socket} = Workflow.Server.handle_connect(socket(false))
    assert socket.joins[@topic].params == %{}
  end

  test "loop-answers-support: start_support runs one support session and pushes support_session with its handle",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "anthropic", "key" => "k"},
      "repo" => repo
    })

    test = self()

    Application.put_env(:workflow, :alloy_run, fn prompt, opts ->
      send(test, {:run, prompt, opts})
      {:ok, %{text: "", messages: [], metadata: %{provider_state: %{session_id: "s-2"}}}}
    end)

    ask = %{
      "project_id" => "p9",
      "thread_id" => "t1",
      "question" => "How do I hand in a story?",
      "resume" => "s-1"
    }

    socket = socket()
    {:ok, socket} = Workflow.Server.handle_message(@topic, "start_support", ask, socket)

    assert_receive {:run, prompt, opts}, 2000
    assert prompt =~ "How do I hand in a story?"
    assert prompt =~ "p9"
    assert prompt =~ "reply_to_support_thread"
    assert prompt =~ "conversation_id t1"
    assert {Alloy.Provider.Anthropic, %{provider_state: %{session_id: "s-1"}}} = opts[:provider]
    assert opts[:working_directory] == repo

    assert_receive {:support_session, %{"thread_id" => "t1", "resume" => "s-2"}} = session, 2000
    {:noreply, socket} = Workflow.Server.handle_info(session, socket)
    assert_received {:pushed, "support_session", %{"thread_id" => "t1", "resume" => "s-2"}, ref}

    log =
      capture_log(fn ->
        {:ok, _socket} =
          Workflow.Server.handle_reply(ref, {:error, %{"error" => "no thread"}}, socket)
      end)

    assert log =~ "support_session t1 refused"

    # One session, and no work: no works file, no copy beside the repo, no slot.
    refute_receive {:run, _, _}, 200
    refute File.exists?(Path.join(dir, "works"))
    assert File.ls!(dir) |> Enum.sort() == ["repo"]
    assert Workflow.Report.in_flight() == []

    # With no resume handle, the session starts fresh.
    {:ok, _socket} =
      Workflow.Server.handle_message(@topic, "start_support", %{ask | "resume" => nil}, socket)

    assert_receive {:run, _prompt, opts}, 2000
    {_provider, config} = opts[:provider]
    refute Map.has_key?(config, :provider_state)
  end

  test "loop-answers-support: a wake from support reaches the manager as a message with its text",
       %{tmp_dir: dir} do
    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => Path.join(dir, "repo")
    })

    test = self()

    Application.put_env(:workflow, :manager_run, fn message, _opts ->
      send(test, {:told, message})
      {:ok, %{text: "noted", messages: []}}
    end)

    wake = %{
      "from" => "support",
      "thread_id" => "t1",
      "agent_id" => "m1",
      "text" => "[From CodeMySpec support] Hand it in by id."
    }

    {:ok, _socket} = Workflow.Server.handle_message(@topic, "wake", wake, socket())
    assert_receive {:told, "[From CodeMySpec support] Hand it in by id."}, 5000
  end
end
