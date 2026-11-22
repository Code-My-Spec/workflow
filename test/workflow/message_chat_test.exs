defmodule Workflow.MessageChatTest do
  # Not async: the server line is registered by name, and the manager is the application's.
  use ExUnit.Case
  import Plug.Test, only: [conn: 3]
  import Plug.Conn, only: [put_req_header: 3]

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    was = for key <- [:manager, :works_dir], do: {key, Application.get_env(:workflow, key)}
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    :ok
  end

  # The server line, faked: each push waited on is sent to the test and answered
  # with `answer` (or, with `:gone`, not answered at all).
  defp server_line(answer) do
    test = self()
    refute GenServer.whereis(Workflow.Server)
    pid = spawn(fn -> serve(test, answer) end)
    Process.register(pid, Workflow.Server)
    on_exit(fn -> Process.exit(pid, :kill) end)
  end

  defp serve(test, answer) do
    receive do
      {:"$gen_call", from, {:push, event, payload}} ->
        send(test, {:pushed, event, payload})
        if answer == :gone, do: exit(:gone)
        GenServer.reply(from, answer)
        serve(test, answer)
    end
  end

  defp message_chat do
    Enum.find(Workflow.Manager.tools(Workflow.Manager.configured()), &(&1.name == "message_chat"))
  end

  test "the-manager-can-message-the-chat: criterion 1 - message_chat pushes message {text} and says it was delivered, with the id" do
    server_line({:ok, %{"id" => "m42"}})

    assert {:ok, said} = message_chat().execute.(%{"text" => "i1 stopped: it needs you"}, %{})

    assert_received {:pushed, "message", %{"text" => "i1 stopped: it needs you"}}
    assert said =~ ~r/delivered/i
    refute said =~ ~r/not delivered/i
    assert said =~ "m42"
  end

  test "the-manager-can-message-the-chat: criterion 2 - a refused message and one with no reply are not delivered, and say why" do
    server_line({:error, %{"reason" => "no chat inbox"}})
    assert {:ok, refused} = message_chat().execute.(%{"text" => "a question"}, %{})
    assert_received {:pushed, "message", %{"text" => "a question"}}
    assert refused =~ ~r/not delivered/i
    assert refused =~ "refused"
    assert refused =~ "no chat inbox"

    Process.unregister(Workflow.Server)
    server_line(:gone)
    assert {:ok, unanswered} = message_chat().execute.(%{"text" => "another"}, %{})
    assert_received {:pushed, "message", %{"text" => "another"}}
    assert unanswered =~ ~r/not delivered/i
    assert unanswered =~ "no reply"
  end

  test "the-manager-can-message-the-chat: criterion 3 - with no server configured, it says so and nothing is sent" do
    refute GenServer.whereis(Workflow.Server)

    assert {:ok, said} = message_chat().execute.(%{"text" => "hello"}, %{})

    assert said =~ "no server"
    assert said =~ "nothing was sent"
    refute_received {:pushed, _event, _payload}
  end

  test "the-manager-can-message-the-chat: criterion 4 - the brief and the tool say when to message the chat, and that routine progress goes through say" do
    test = self()

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:run, opts})
      {:ok, %{text: "ok", messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :manager_run) end)

    Workflow.Manager.tell("anything")
    assert_received {:run, opts}

    for brief <- [opts[:system_prompt], message_chat().description] do
      brief = String.downcase(brief)
      assert brief =~ "message_chat" or brief =~ "the person's chat"
      assert brief =~ "must know or decide something now"
      assert brief =~ "a question only they can answer"
      assert brief =~ "a stopped work"
      assert brief =~ "a red that needs them"
      assert brief =~ "not for routine progress"
      assert brief =~ "say"
    end

    assert String.downcase(opts[:system_prompt]) =~ "message_chat"
  end

  test "the-manager-can-message-the-chat: criterion 5 - POST /manager can ask for a chat message, and it is sent through message_chat" do
    server_line({:ok, %{"id" => "m7"}})

    # The manager's turn, faked: it sends the message it was asked to with its own tool.
    Application.put_env(:workflow, :manager_run, fn message, opts ->
      tool = Enum.find(opts[:tools], &(&1.name == "message_chat"))

      {:ok, said} =
        tool.execute.(%{"text" => String.replace_prefix(message, "tell the chat: ", "")}, %{})

      {:ok, %{text: said, messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :manager_run) end)

    conn =
      :post
      |> conn("/manager", Jason.encode!(%{say: "tell the chat: i1 needs a decision"}))
      |> put_req_header("content-type", "application/json")
      |> Workflow.Router.call(Workflow.Router.init([]))

    assert conn.status == 200
    assert_received {:pushed, "message", %{"text" => "i1 needs a decision"}}
    assert %{"said" => said} = Jason.decode!(conn.resp_body)
    assert said =~ "m7"
  end
end
