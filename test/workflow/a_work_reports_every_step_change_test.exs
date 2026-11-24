defmodule Workflow.AWorkReportsEveryStepChangeTest do
  # Not async: the command a checkout runs, the agent, the server's line and
  # where works in flight are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias Workflow.Checkout

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    was =
      for key <- [:cmd, :works_dir, :agents_run, :push, :server, :manager],
          do: {key, Application.get_env(:workflow, key)}

    # Git is real; `just` and agent-browser are never run, and pass.
    Application.put_env(:workflow, :cmd, fn
      command, _args, _opts when command in ["just", "agent-browser"] -> {"", 0}
      command, args, opts -> System.cmd(command, args, opts)
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    # No such remote: promote merges into the main copy and pushes nothing.
    Application.put_env(:workflow, :push, %{"remote" => "nowhere", "branch" => "main"})
    Application.put_env(:workflow, :server, %{"url" => "ws://x", "project_id" => "p1"})
    Application.delete_env(:workflow, :manager)

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    git(main, ~w(init -q -b main))
    git(main, ~w(config user.name t))
    git(main, ~w(config user.email t@example.com))
    commit(main, "fix.txt", "broken\n", "first")

    root = Checkout.root(main, "i1")
    git(main, ["worktree", "add", "-q", "-b", "issue/i1", root])

    work = %{
      "kind" => "issue",
      "id" => "i1",
      "root" => root,
      "repo" => main,
      "agent" => %{"provider" => "claude-code"}
    }

    stand_in()
    %{main: main, root: root, work: work}
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit(dir, file, content, message) do
    File.write!(Path.join(dir, file), content)
    git(dir, ["add", file])
    git(dir, ["commit", "-q", "-m", message])
  end

  # A fake server line: each report it is handed is told the test as pushed.
  defp stand_in do
    test = self()
    pid = spawn_link(fn -> forward(test) end)
    Process.register(pid, Workflow.Server)
  end

  defp forward(test) do
    receive do
      {:report, report} ->
        send(test, {:pushed, report})
        forward(test)
    end
  end

  # A fake agent: the fix turn tells the test and is held until the work is
  # stopped; a review passes.
  defp agent do
    test = self()

    Application.put_env(:workflow, :agents_run, fn
      %{name: "fix"}, _work ->
        send(test, :fix_turn)
        Process.sleep(:infinity)

      %{name: "review"}, _work ->
        {%{"status" => "pass"}, nil}
    end)
  end

  defp flush do
    receive do
      _any -> flush()
    after
      0 -> :ok
    end
  end

  defp stop(work) do
    capture_log(fn ->
      Workflow.Run.cancel(Map.delete(work, "root"))
      Workflow.Settled.idle()
    end)
  end

  test "a-work-reports-every-step-change: criterion 1 - a hand-in pushes a report with the work's whole picture at once",
       %{work: work} do
    agent()

    capture_log(fn -> assert {%{name: "fix"}, "started"} = Workflow.Run.start(work) end)

    # The coder's turn is held: nothing has been recorded, yet the server is told.
    assert_receive :fix_turn, 5_000
    assert_received {:pushed, %{"work" => "i1"} = report}

    assert %{"step" => "fix", "status" => "running", "kind" => "issue"} = report
    assert [%{"name" => "fix"} | _] = report["steps"]

    stop(work)
  end

  test "a-work-reports-every-step-change: criterion 3 - a red ci event that sends a work back to fix pushes a report whose step is fix",
       %{main: main, root: root, work: work} do
    agent()
    commit(root, "fix.txt", "fixed\n", "issue i1: the fix")

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      Workflow.Settled.idle()
    end)

    assert %{step: "ci", actor: :external} = Workflow.Run.look(work)
    assert Checkout.landed?(main, "issue", "i1")
    Process.sleep(300)
    flush()

    capture_log(fn ->
      assert Workflow.Run.event("i1", "ci", %{"verdict" => "red", "failing" => ["t1"]}) == :ok
      assert_receive :fix_turn, 5_000
    end)

    assert_received {:pushed, %{"work" => "i1", "step" => "fix", "status" => "running"}}

    stop(work)
  end

  test "a-work-reports-every-step-change: criterion 4 - reports not sent while the channel is down are sent on reconnect, each work's newest picture last" do
    down = Slipstream.new_socket() |> Slipstream.Socket.assign(:topic, "loop:p1")

    reports = [
      %{"work" => "w1", "step" => "promote", "status" => "running"},
      %{"work" => "w2", "step" => "fix", "status" => "running"},
      %{"work" => "w1", "step" => "ci", "status" => "running"},
      %{"work" => "w1", "step" => "fix", "status" => "running"}
    ]

    # The line is not joined: every push fails.
    down =
      Enum.reduce(reports, down, fn report, socket ->
        me = self()

        capture_log(fn ->
          send(me, {:socket, Workflow.Server.handle_info({:report, report}, socket)})
        end)

        assert_received {:socket, {:noreply, socket}}
        socket
      end)

    refute_received {:report, _}

    assert {:ok, joined} = Workflow.Server.handle_join("loop:p1", %{}, down)
    sent = receive_reports()

    assert %{"step" => "fix"} = sent |> Enum.filter(&(&1["work"] == "w1")) |> List.last()
    assert %{"step" => "fix"} = sent |> Enum.filter(&(&1["work"] == "w2")) |> List.last()

    # Sent once: not again at the join after.
    assert {:ok, _joined} = Workflow.Server.handle_join("loop:p1", %{}, joined)
    assert receive_reports() == []
  end

  defp receive_reports(acc \\ []) do
    receive do
      {:report, report} -> receive_reports([report | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
