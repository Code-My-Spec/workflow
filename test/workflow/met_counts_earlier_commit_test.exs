defmodule Workflow.MetCountsEarlierCommitTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp git(dir, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args],
        cd: dir,
        stderr_to_stdout: true
      )

    out
  end

  # A real repository whose work branch was cut from `trunk`.
  defp repo(dir) do
    git(dir, ~w(init -q -b trunk))
    File.write!(Path.join(dir, "README"), "x\n")
    git(dir, ~w(add README))
    git(dir, ~w(commit -q -m init))
    git(dir, ~w(checkout -q -b story/s1))
    File.mkdir_p!(Path.join(dir, "test"))
    dir
  end

  defp write_test(dir, text),
    do: File.write!(Path.join([dir, "test", "s1_test.exs"]), "test \"#{text}\" do\nend\n")

  # The tree qa's turn left: the run passed and qa called the part met (or not),
  # with `commits` on the branch now and `from` before qa's turn.
  defp snapshot(dir, met, commits, from) do
    found = %{
      "run" => %{"status" => "passed"},
      "by" => %{"step" => "specify", "from" => from}
    }

    found = if met, do: Map.put(found, "specify", %{"status" => "pass"}), else: found
    snapshot = %{head: "t", main: "trunk", commits: commits, results: %{"t" => found}}
    work = %{"id" => "s1", "root" => dir, "criteria" => ["a", "b"]}
    Map.merge(snapshot, Workflow.Story.observe(work, snapshot))
  end

  test "met-counts-an-earlier-test-commit: criterion 1 - a test committed in an earlier turn backs a criterion called met with no commit",
       %{tmp_dir: dir} do
    repo(dir)
    # qa commits criterion 1's test in one turn...
    write_test(dir, "s1: criterion 1 does a")
    git(dir, ~w(add test))
    git(dir, ~w(commit -q -m qa))

    # ...and calls it met in the next, committing nothing: the work moves on.
    assert %{stage: 2, note: "Write one test for criterion 2" <> _} =
             Workflow.Story.status(%{name: "specify"}, snapshot(dir, true, 1, 1))
  end

  test "met-counts-an-earlier-test-commit: criterion 2 - a criterion called met with no committed test on the branch is sent back",
       %{tmp_dir: dir} do
    repo(dir)
    # The test is on the tree but no commit on the branch holds it.
    write_test(dir, "s1: criterion 1 does a")

    assert %{stage: 1, note: "You called criterion 1 already met but committed no test." <> _} =
             Workflow.Story.status(%{name: "specify"}, snapshot(dir, true, 0, 0))
  end

  test "met-counts-an-earlier-test-commit: criterion 3 - a criterion not called met must still fail first",
       %{tmp_dir: dir} do
    repo(dir)
    write_test(dir, "s1: criterion 1 does a")
    git(dir, ~w(add test))
    git(dir, ~w(commit -q -m qa))

    assert %{stage: 1, note: "The test for criterion 1 passes already." <> _} =
             Workflow.Story.status(%{name: "specify"}, snapshot(dir, false, 1, 0))
  end
end
