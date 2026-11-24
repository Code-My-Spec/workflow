defmodule Workflow.AWorkThatEndsSendsALastReportTest do
  # Not async: the command a checkout runs, the agent, the server's line and
  # where works in flight are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias Workflow.Checkout

  @ended ["done", "stopped", "released"]

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
    commit(root, "fix.txt", "fixed\n", "issue i1: the fix")

    work = %{
      "kind" => "issue",
      "id" => "i1",
      "root" => root,
      "repo" => main,
      "agent" => %{"provider" => "claude-code"}
    }

    file = Path.join([dir, "works", "i1.json"])
    stand_in()
    %{main: main, root: root, work: work, in_flight: file}
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

  # A fake server line: each report it is handed is told the test as pushed, so
  # the test's own `{:report, _}` are only what a join sends itself.
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

  # Every last report pushed for i1 within a while.
  defp last_reports(acc \\ []) do
    receive do
      {:pushed, %{"work" => "i1", "status" => status} = report} when status in @ended ->
        last_reports([report | acc])

      {:pushed, _report} ->
        last_reports(acc)
    after
      500 -> Enum.reverse(acc)
    end
  end

  defp flush do
    receive do
      _any -> flush()
    after
      0 -> :ok
    end
  end

  # In flight, its tree committed and not yet certified.
  defp in_flight(work, file) do
    Checkout.keep(work["root"], "i1", work)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Jason.encode!(work))
  end

  # Through certify, review (passed) and promote, and left waiting on ci.
  defp at_ci(work, main, file) do
    Application.put_env(:workflow, :agents_run, fn
      %{name: "review"}, _work -> {%{"status" => "pass"}, nil}
      step, _work -> flunk("no #{step.name} turn was expected")
    end)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      Workflow.Settled.idle()
    end)

    assert %{step: "ci", actor: :external} = Workflow.Run.look(work)
    assert Checkout.landed?(main, "issue", "i1")
    assert File.exists?(file)
    Process.sleep(300)
    flush()
  end

  test "a-work-that-ends-sends-a-last-report: criterion 1 - stopping a work pushes exactly one last report, stopped, with the step it ended at, before its file is removed",
       %{work: work, in_flight: file} do
    in_flight(work, file)
    assert %{step: "" <> step} = Workflow.Run.look(work)
    flush()

    capture_log(fn -> Workflow.Run.cancel(Map.delete(work, "root")) end)

    assert [report] = last_reports()
    assert %{"status" => "stopped", "step" => ^step, "kind" => "issue"} = report
    refute File.exists?(file)
  end

  test "a-work-that-ends-sends-a-last-report: criterion 2 - releasing a work waiting at ci pushes exactly one last report, released, at ci, before its file is removed",
       %{main: main, work: work, in_flight: file} do
    at_ci(work, main, file)

    capture_log(fn -> Workflow.Run.cancel(Map.delete(work, "root")) end)

    assert [report] = last_reports()
    assert %{"status" => "released", "step" => "ci"} = report
    refute File.exists?(file)
  end

  test "a-work-that-ends-sends-a-last-report: criterion 3 - a work finished by its ci event pushes exactly one last report, done, at ci, before its file is removed, and a stop after it sends none",
       %{main: main, work: work, in_flight: file} do
    at_ci(work, main, file)

    capture_log(fn ->
      assert Workflow.Run.event("i1", "ci", %{"verdict" => "green"}) == :ok
      Workflow.Settled.idle()
    end)

    assert [report] = last_reports()
    assert %{"status" => "done", "step" => "ci"} = report
    refute File.exists?(file)

    # Two paths ending one work: the stop after it sends no second last report.
    capture_log(fn -> Workflow.Run.cancel(Map.delete(work, "root")) end)
    assert last_reports() == []
  end

  test "a-work-that-ends-sends-a-last-report: criterion 4 - with the line down as a work ends, its last report is kept and pushed once on reconnect",
       %{work: work, in_flight: file} do
    in_flight(work, file)
    flush()
    capture_log(fn -> Workflow.Run.cancel(Map.delete(work, "root")) end)
    assert [report] = last_reports()

    # The line is not joined: the push fails, and the report is kept.
    down = Slipstream.new_socket() |> Slipstream.Socket.assign(:topic, "loop:p1")

    {:noreply, down} =
      capture_log_result(fn -> Workflow.Server.handle_info({:report, report}, down) end)

    refute_received {:report, _}

    # Joined again: pushed once, and not again at the join after.
    assert {:ok, joined} = Workflow.Server.handle_join("loop:p1", %{}, down)
    assert_receive {:report, %{"work" => "i1", "status" => "stopped"} = ^report}
    refute_receive {:report, _}, 100

    assert {:ok, _joined} = Workflow.Server.handle_join("loop:p1", %{}, joined)
    refute_receive {:report, _}, 100
  end

  defp capture_log_result(fun) do
    me = self()
    capture_log(fn -> send(me, {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end
end
