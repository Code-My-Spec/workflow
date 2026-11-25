defmodule Workflow.RestartResumesAgentsAgainTest do
  # Not async: the command a checkout runs, the agent, the manager, and where
  # works in flight are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    test = self()

    was =
      for key <- [:cmd, :works_dir, :agents_run, :manager, :manager_run, :recipients, :server],
          do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    # No server, no manager unless a test names one; never the real works dir.
    for key <- [:server, :manager, :recipients], do: Application.delete_env(:workflow, key)
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      {:ok, %{text: "noted", messages: opts[:messages]}}
    end)

    # Git is real, but slow in the checkout `slow` names, until told to go;
    # `just` and agent-browser are never run.
    {:ok, slow} = Agent.start_link(fn -> nil end)

    Application.put_env(:workflow, :cmd, fn
      "just", _args, _opts ->
        {"", 0}

      "agent-browser", _args, _opts ->
        {"", 0}

      command, args, opts ->
        if opts[:cd] && opts[:cd] == Agent.get(slow, & &1) do
          Agent.update(slow, fn _ -> nil end)
          send(test, {:slow, self()})
          receive do: (:go -> :ok)
        end

        System.cmd(command, args, opts)
    end)

    # Each agent says it is at work and stays at it until told to end, or until
    # the test is ending; ended, its run errs, so the work stops and its slot frees.
    {:ok, ending} = Agent.start_link(fn -> false end)

    Application.put_env(:workflow, :agents_run, fn step, %{"id" => id} ->
      send(test, {:agent, id, step.name, self()})
      at_work(ending)
    end)

    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    git(main, ~w(init -q -b main))
    git(main, ~w(config user.name t))
    git(main, ~w(config user.email t@example.com))
    commit(main, "README.md", "hello\n", "first")

    %{dir: dir, main: main, slow: slow, ending: ending}
  end

  defp at_work(ending) do
    receive do
      :end -> {%{}, "ended"}
    after
      50 -> if Agent.get(ending, & &1), do: {%{}, "ended"}, else: at_work(ending)
    end
  end

  # Every agent ends, and every run the loop started is waited on.
  defp finish(%{ending: ending}) do
    Agent.update(ending, fn _ -> true end)
    Workflow.Settled.idle()
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

  # A work's checkout with `commits` commits of its own, kept in flight as the
  # loop keeps it, with `turn` when its agent was at work on that step.
  defp in_flight(%{dir: dir, main: main}, kind, id, commits, turn \\ nil) do
    root = Path.join(dir, id)
    git(main, ["worktree", "add", "-q", "-b", "#{kind}/#{id}", root])
    for n <- 1..commits//1, do: commit(root, "#{id}-#{n}.txt", "#{n}\n", "#{id}: commit #{n}")

    work = %{
      "kind" => kind,
      "id" => id,
      "root" => root,
      "agent" => %{"provider" => "claude-code"}
    }

    work =
      if turn,
        do: Map.put(work, "turn", %{"step" => turn, "note" => "#{id} at #{turn}"}),
        else: work

    works = Path.join(dir, "works")
    File.mkdir_p!(works)
    File.write!(Path.join(works, "#{id}.json"), Jason.encode!(work))
    work
  end

  # Ends an agent's turn, and the second run the loop gives it.
  defp end_turn(pid), do: for(_ <- 1..2, do: send(pid, :end))

  # A work earlier in the list whose checkout is slow to answer git: resume is
  # held on it until it goes, as it was seen held on every work before.
  defp slow_before(ctx) do
    %{"root" => root} = in_flight(ctx, "issue", "a0", 1)
    Agent.update(ctx.slow, fn _ -> root end)
  end

  defp go do
    assert_receive {:slow, pid}, 5_000
    send(pid, :go)
  end

  test "restart-resumes-agents-again: criterion 1 - after a restart with an issue work mid-fix, its fix step gets an agent again",
       ctx do
    slow_before(ctx)
    in_flight(ctx, "issue", "i1", 1, "fix")

    capture_log(fn ->
      resume = Task.async(&Workflow.Run.resume/0)

      # Its agent is back at fix, with its note, while the work before it is still held.
      assert_receive {:agent, "i1", "fix", pid}, 5_000
      refute_received {:agent, "a0", _step, _pid}

      go()
      Task.await(resume, 15_000)
      end_turn(pid)
      finish(ctx)
    end)
  end

  test "restart-resumes-agents-again: criterion 2 - after a restart with a story work mid-work, its work step gets an agent again, keeping its commits",
       ctx do
    slow_before(ctx)
    %{"root" => root} = in_flight(ctx, "story", "s1", 3, "work")
    head = git(root, ~w(rev-parse HEAD))
    log = git(root, ~w(log --format=%s))

    capture_log(fn ->
      resume = Task.async(&Workflow.Run.resume/0)

      assert_receive {:agent, "s1", "work", pid}, 5_000
      # Its commits and history are as they were.
      assert git(root, ~w(rev-parse HEAD)) == head
      assert git(root, ~w(log --format=%s)) == log
      assert git(root, ~w(rev-list --count main..HEAD)) == "3"

      go()
      Task.await(resume, 15_000)
      end_turn(pid)
      finish(ctx)
    end)
  end

  test "restart-resumes-agents-again: criterion 3 - after a restart with more mid-step works than the cap, only up to the cap get agents and the rest start as slots free",
       ctx do
    agent = %{"provider" => "claude-code"}

    Application.put_env(:workflow, :manager, %{
      "agent" => agent,
      "repo" => ctx.main,
      "agents" => %{"coder" => agent, "reviewer" => agent},
      "cap" => 2
    })

    for id <- ~w(i1 i2 i3), do: in_flight(ctx, "issue", id, 1, "fix")

    capture_log(fn ->
      assert Workflow.Run.resume() == :ok

      assert_receive {:agent, first, "fix", pid}, 5_000
      assert_receive {:agent, second, "fix", other}, 5_000
      refute_receive {:agent, _third, _step, _pid}, 1_000
      [third] = ~w(i1 i2 i3) -- [first, second]

      # One turn ends and its work stops: the slot it frees is the third's, at fix.
      end_turn(pid)
      assert_receive {:agent, ^third, "fix", last}, 15_000

      end_turn(other)
      end_turn(last)
      finish(ctx)
    end)
  end
end
