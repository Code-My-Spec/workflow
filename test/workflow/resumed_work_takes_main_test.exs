defmodule Workflow.ResumedWorkTakesMainTest do
  # Not async: the command a checkout runs, and where works in flight are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    test = self()
    was = for key <- [:cmd, :works_dir], do: {key, Application.get_env(:workflow, key)}

    # Git is real; `just` is never run, only told to the test.
    Application.put_env(:workflow, :cmd, fn
      "just", args, _opts ->
        send(test, {:just, args})
        {"", 1}

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
    commit(main, "justfile", "run dir:\n    echo old\n", "first")

    # The work's kept branch, as a hand-in by id left it.
    work = Workflow.Checkout.root(main, "i1")
    File.rm_rf!(work)
    git(main, ["worktree", "add", "-q", "-b", "issue/i1", work])
    on_exit(fn -> File.rm_rf!(work) end)

    %{main: main, work: work}
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

  defp hand_in(main), do: %{"kind" => "issue", "id" => "i1", "repo" => main}

  test "resumed-work-takes-main: criterion 1 - a work resumed by id has main merged into its branch before its first step",
       %{main: main, work: work} do
    commit(main, "justfile", "run dir:\n    echo new\n", "a changed justfile")

    capture_log(fn ->
      assert {%{name: "fix"}, nil} = Workflow.Run.start(hand_in(main))
    end)

    assert File.read!(Path.join(work, "justfile")) =~ "echo new"
    assert git(work, ~w(rev-parse HEAD)) == git(main, ~w(rev-parse HEAD))
  end

  test "resumed-work-takes-main: criterion 2 - a resumed work whose branch conflicts with main stops saying so and runs no step",
       %{main: main, work: work} do
    commit(work, "justfile", "run dir:\n    echo ours\n", "the work's")
    commit(main, "justfile", "run dir:\n    echo theirs\n", "main's")

    capture_log(fn ->
      assert {%{name: "merge-main", stop: true, note: note}, "stopped: " <> _} =
               Workflow.Run.start(hand_in(main))

      assert note =~ "merge of `main`"
      assert note =~ "conflicted"
      assert note =~ "justfile"
    end)

    assert %{"step" => "merge-main", "reason" => reason} = Workflow.Run.stopped(hand_in(main))
    assert reason =~ "conflicted"
    refute_received {:just, _args}
    assert git(work, ~w(status --porcelain)) == ""
  end

  test "resumed-work-takes-main: criterion 3 - a tree dirty only with untracked leftovers ignored in main has the git status text in its stop note",
       %{main: main, work: work} do
    commit(main, ".gitignore", "leftovers/\n", "ignore leftovers")
    commit(work, "fix.txt", "fixed\n", "the fix")
    File.mkdir_p!(Path.join(work, "leftovers"))
    File.write!(Path.join([work, "leftovers", "x.log"]), "x\n")
    status = git(work, ~w(status --short))
    assert status =~ "leftovers/"

    work_given = %{"kind" => "issue", "id" => "i1", "root" => work}

    capture_log(fn ->
      assert {%{name: "certify"}, reason} = Workflow.Run.start(work_given)
      assert reason =~ status
    end)

    assert Workflow.Run.stopped(work_given)["reason"] =~ status
    refute_received {:just, _args}
  end
end
