defmodule Workflow.ALandedWorkResumesWaitingOnCiTest do
  # Not async: the command a checkout runs, the agent, and where works in flight
  # are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias Workflow.Checkout

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    test = self()

    was =
      for key <- [:cmd, :works_dir, :agents_run, :push, :server],
          do: {key, Application.get_env(:workflow, key)}

    # A server is configured, so a landed work waits at ci for its event; its
    # state dir holds no sign-in, so nothing is asked of it.
    Application.put_env(:workflow, :server, %{
      "url" => "ws://x",
      "project_id" => "p1",
      "state_dir" => Path.join(dir, "state")
    })

    # Git is real; `just` is never run, only told to the test, and passes.
    Application.put_env(:workflow, :cmd, fn
      "just", args, _opts ->
        send(test, {:just, args})
        {"", 0}

      command, args, opts ->
        System.cmd(command, args, opts)
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    # No such remote: promote merges into the main copy and pushes nothing.
    Application.put_env(:workflow, :push, %{"remote" => "nowhere", "branch" => "main"})

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

    root = Path.join(dir, "i1")
    git(main, ["worktree", "add", "-q", "-b", "issue/i1", root])
    commit(root, "fix.txt", "fixed\n", "issue i1: the fix")

    work = %{
      "kind" => "issue",
      "id" => "i1",
      "root" => root,
      "repo" => main,
      "agent" => %{"provider" => "claude-code"}
    }

    %{main: main, root: root, work: work, in_flight: Path.join([dir, "works", "i1.json"])}
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

  # The work goes through certify, review (passed) and promote, and is left
  # waiting on ci, landed in the main copy, as the service had it.
  defp land(work, main, file) do
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
    flush()

    # Restarted: anything run from here on is told to the test.
    test = self()

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:agent, step.name, step.note})
      {%{}, nil}
    end)

    git(main, ~w(rev-parse HEAD))
  end

  defp flush do
    receive do
      _any -> flush()
    after
      0 -> :ok
    end
  end

  test "a-landed-work-resumes-waiting-on-ci: criterion 1 - a landed work with no ci event resumes waiting at ci after a restart, runs no certify, fix, review or promote, and a ci event afterwards finishes it",
       %{main: main, work: work, in_flight: file} do
    landed_at = land(work, main, file)

    log =
      capture_log(fn ->
        assert Workflow.Run.resume() == :ok
        Workflow.Settled.idle()
      end)

    refute log =~ "[Workflow i1] certify"
    refute log =~ "[Workflow i1] promote"
    refute_received {:just, _args}
    refute_received {:agent, _step, _note}
    assert File.exists?(file), "the work waiting on ci is no longer in flight"
    assert %{step: "ci", actor: :external, done: false} = Workflow.Run.look(work)
    assert git(main, ~w(rev-parse HEAD)) == landed_at

    # The ci for the commit it landed as comes in, green, and the work is done.
    capture_log(fn ->
      assert Workflow.Run.event("i1", "ci", %{"verdict" => "green"}) == :ok
      Workflow.Settled.idle()
    end)

    refute File.exists?(file)
    assert %{done: true} = Workflow.Run.look(work)
    refute_received {:just, _args}
    refute_received {:agent, _step, _note}
    assert git(main, ~w(rev-parse HEAD)) == landed_at
  end

  test "a-landed-work-resumes-waiting-on-ci: criterion 2 - a landed work whose ci event is recorded is handled by its verdict after a restart, and is not re-landed",
       %{main: main, root: root, work: work, in_flight: file} do
    landed_at = land(work, main, file)
    kept = File.read!(file)

    # Red: back to fix with ci's note, nothing re-run or re-landed.
    Checkout.record(root, "i1", "ci", %{
      "event" => "ci",
      "verdict" => "red",
      "failing" => ["a test"]
    })

    log =
      capture_log(fn ->
        assert Workflow.Run.resume() == :ok
        Workflow.Settled.idle()
      end)

    refute log =~ "[Workflow i1] certify"
    refute log =~ "[Workflow i1] promote"
    refute_received {:just, _args}
    assert_received {:agent, "fix", note}
    assert note =~ "ci failed"
    assert note =~ "a test"
    assert git(main, ~w(rev-parse HEAD)) == landed_at

    # Green, kept in flight when the service went down: done, not re-landed.
    Checkout.record(root, "i1", "ci", %{"event" => "ci", "verdict" => "green"})
    File.write!(file, kept)
    flush()

    capture_log(fn ->
      assert Workflow.Run.resume() == :ok
      Workflow.Settled.idle()
    end)

    refute_received {:just, _args}
    refute_received {:agent, _step, _note}
    refute File.exists?(file)
    assert %{done: true} = Workflow.Run.look(work)
    assert git(main, ~w(rev-parse HEAD)) == landed_at
  end
end
