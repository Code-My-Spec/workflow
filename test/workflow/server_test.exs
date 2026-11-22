defmodule Workflow.ServerTest do
  use ExUnit.Case, async: false

  setup do
    was = Application.get_env(:workflow, :manager)
    on_exit(fn -> Application.put_env(:workflow, :manager, was) end)
  end

  test "a say is answered with the manager's reply under the same ref, or says why not" do
    Application.put_env(:workflow, :manager, %{"agent" => %{"provider" => "claude-code"}})
    say = %{"ref" => "r1", "text" => "hello"}

    assert {"said", %{"ref" => "r1", "text" => "hi back"}} =
             Workflow.Server.answer(say, fn "hello" -> "hi back" end)

    assert {"said", %{"ref" => "r1", "text" => "The manager failed" <> _}} =
             Workflow.Server.answer(say, fn _ -> raise "boom" end)

    Application.delete_env(:workflow, :manager)

    assert {"said", %{"ref" => "r1", "text" => "The loop has no manager" <> _}} =
             Workflow.Server.answer(say, fn _ -> flunk("not asked") end)
  end

  @topic "loop:p1"
  @crash {:error, %{"reason" => "channel_crash"}}

  # A fake channel process: every push is told to the test and answered with a ref.
  defp fake_channel do
    test = self()

    spawn_link(fn ->
      Stream.repeatedly(fn ->
        receive do
          {:"$gen_call", from, {_, %Slipstream.Commands.PushMessage{} = push}} ->
            send(test, {:pushed, push.event, push.payload})
            GenServer.reply(from, {:ok, make_ref()})
        end
      end)
      |> Stream.run()
    end)
  end

  defp socket do
    %{
      Slipstream.Socket.new()
      | channel_pid: fake_channel(),
        channel_config: Slipstream.Configuration.validate!(uri: "ws://localhost/socket/websocket")
    }
    |> Slipstream.Socket.assign(topic: @topic, server: %{}, started: true)
    |> joined()
  end

  # What Slipstream does to the socket when a join succeeds.
  defp joined(socket) do
    join = %Slipstream.Socket.Join{topic: @topic, params: %{}, status: :joined, rejoin_counter: 0}
    put_in(socket.joins[@topic], join)
  end

  defp close(socket, reason) do
    socket = put_in(socket.joins[@topic].status, :closed)
    {:ok, socket} = Workflow.Server.handle_topic_close(@topic, reason, socket)
    socket
  end

  # Runs what the process sent itself (reports queued on join) through it.
  defp drain(socket) do
    receive do
      {:report, _} = report ->
        {:noreply, socket} = Workflow.Server.handle_info(report, socket)
        drain(socket)
    after
      0 -> socket
    end
  end

  test "a channel crash straight after a report stops reports for good, warned once, and a say is still answered" do
    Application.delete_env(:workflow, :manager)
    report = %{"work" => "w1"}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        socket = socket()
        {:noreply, socket} = Workflow.Server.handle_info({:report, report}, socket)
        assert_received {:pushed, "report", ^report}

        socket = close(socket, @crash)

        socket =
          Enum.reduce(1..3, socket, fn _, socket ->
            {:ok, socket} = Workflow.Server.handle_join(@topic, %{}, joined(socket))
            socket = drain(socket)
            {:noreply, socket} = Workflow.Server.handle_info({:report, report}, socket)
            close(socket, @crash)
          end)

        refute_received {:pushed, "report", _}

        socket = joined(socket)
        say = %{"ref" => "r9", "text" => "still there?"}
        {:ok, socket} = Workflow.Server.handle_message(@topic, "say", say, socket)
        assert_receive {:said, _} = said, 1000
        {:noreply, _socket} = Workflow.Server.handle_info(said, socket)
        assert_received {:pushed, "said", %{"ref" => "r9", "text" => "" <> _}}
      end)

    assert length(String.split(log, "does not take reports")) == 2
  end

  test "each close waits longer before the rejoin, up to a cap, even when every join succeeds" do
    ExUnit.CaptureLog.capture_log(fn ->
      steps = Slipstream.Configuration.validate!(uri: "ws://x/socket/websocket").rejoin_after_msec

      {delays, _} =
        Enum.map_reduce(1..10, socket(), fn _, socket ->
          socket = close(socket, {:error, %{"reason" => "closed"}})
          # Slipstream's own rule: the pause is the count's place in rejoin_after_msec.
          n = socket.joins[@topic].rejoin_counter - 1
          {Enum.at(steps, n, List.last(steps)), joined(socket)}
        end)

      assert delays == Enum.sort(delays)
      assert hd(delays) < List.last(delays)
      assert Enum.drop(delays, 5) |> Enum.uniq() == [List.last(steps)]
      assert List.last(steps) >= 1000
    end)
  end
end
