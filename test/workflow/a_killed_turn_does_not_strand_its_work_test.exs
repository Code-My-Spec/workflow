defmodule Workflow.AKilledTurnDoesNotStrandItsWorkTest do
  # Not async: the command a checkout runs, the agent, and where works in flight
  # are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    test = self()

    was =
      for key <- [:cmd, :works_dir, :agents_run], do: {key, Application.get_env(:workflow, key)}

    # Git is real; `just` is never run, only told to the test, and passes.
    Application.put_env(:workflow, :cmd, fn
      "just", args, _opts ->
        send(test, {:just, args})
        {"", 0}

      command, args, opts ->
        System.cmd(command, args, opts)
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

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
    commit(root, "fix.txt", "fixed\n", "the fix")

    work = %{
      "kind" => "issue",
      "id" => "i1",
      "root" => root,
      "agent" => %{"provider" => "claude-code"}
    }

    %{root: root, work: work, in_flight: Path.join([dir, "works", "i1.json"])}
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

  # Waits until the work is no longer kept in flight.
  defp landed(file, tries \\ 500) do
    cond do
      not File.exists?(file) -> :ok
      tries == 0 -> flunk("#{file} still in flight")
      true -> Process.sleep(10) && landed(file, tries - 1)
    end
  end

  # The agent left at work is ended, and its work's landing waited on.
  defp end_turn(root, file) do
    with pid when is_pid(pid) <- :global.whereis_name({Workflow.Run, :turns, root}),
         do: Process.exit(pid, :kill)

    landed(file)
  end

  test "a-killed-turn-does-not-strand-its-work: criterion 1 - a work killed mid coder turn after a failed review resumes with its coder, not on certify",
       %{root: root, work: work, in_flight: file} do
    test = self()

    # The reviewer fails the fix; the coder starts editing and is still at it.
    Application.put_env(:workflow, :agents_run, fn
      %{name: "review"}, _work ->
        {%{"status" => "fail", "note" => "add a test"}, nil}

      %{name: "fix"} = step, _work ->
        File.write!(Path.join(root, "fix.txt"), "half fixed\n")
        send(test, {:coder, self(), step.note})
        receive do: (:never -> {%{}, nil})
    end)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      assert_receive {:coder, turns, "The review failed: add a test"}, 5_000
      kept = File.read!(file)

      # The service goes down mid-edit: what was in flight is what a restart reads.
      Process.exit(turns, :kill)
      landed(file)
      File.write!(file, kept)
      assert git(root, ~w(status --short)) =~ "fix.txt"

      Application.put_env(:workflow, :agents_run, fn step, _work ->
        send(test, {:resumed, step.name, step.note})
        receive do: (:never -> {%{}, nil})
      end)

      assert Workflow.Run.resume() == :ok
      assert_receive {:resumed, "fix", note}, 5_000
      assert note == "The review failed: add a test"
      assert Workflow.Run.stopped(work) == nil
      end_turn(root, file)
    end)
  end

  test "a-killed-turn-does-not-strand-its-work: criterion 2 - a dirty tree at a system step with no agent at work goes to the coder with git's status as its note, and the work does not stop",
       %{root: root, work: work, in_flight: file} do
    test = self()
    File.write!(Path.join(root, "fix.txt"), "half fixed\n")
    status = git(root, ~w(status --short))

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:coder, step.name, step.note})
      receive do: (:never -> {%{}, nil})
    end)

    capture_log(fn ->
      assert {%{name: "fix"}, "started"} = Workflow.Run.start(work)
      assert_receive {:coder, "fix", note}, 5_000
      assert note =~ "`git status --short` says"
      assert note =~ status
      assert note =~ "Finish them or drop them, commit with git, then end your turn."
      assert Workflow.Run.stopped(work) == nil
      end_turn(root, file)
    end)

    # Nothing the system does ran on the dirty tree.
    refute_received {:just, _args}
  end
end
