defmodule Workflow.CiCheckoutsPrunedTest do
  # Not async: the command a checkout runs is swapped for the whole application.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias Workflow.Checkout

  # A repository with two commits, by real git. Answers the main copy and both commits.
  defp repo(dir) do
    main = Path.join(dir, "main")
    File.mkdir_p!(main)

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: main, stderr_to_stdout: true)
      String.trim(out)
    end

    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.name", "t"])
    git.(["config", "user.email", "t@example.com"])
    File.write!(Path.join(main, "a"), "1")
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "first"])
    first = git.(["rev-parse", "HEAD"])
    File.write!(Path.join(main, "a"), "2")
    git.(["commit", "-qam", "second"])
    {main, first, git.(["rev-parse", "HEAD"])}
  end

  # Real git, a project with no ci recipe (green), and `hook` asked first about every command.
  defp stand_in(hook \\ fn _command, _args, _opts -> nil end) do
    Application.put_env(:workflow, :cmd, fn command, args, opts ->
      hook.(command, args, opts) ||
        case command do
          "git" -> System.cmd("git", args, opts)
          "just" -> {"error: Justfile does not contain recipe `ci`", 1}
        end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)
  end

  defp ci_dir(main) do
    {git_dir, 0} =
      System.cmd("git", ~w(rev-parse --path-format=absolute --git-common-dir), cd: main)

    Path.join([String.trim(git_dir), "workflow", "ci"])
  end

  defp listed(main) do
    {list, 0} = System.cmd("git", ~w(worktree list --porcelain), cd: main)
    list
  end

  test "ci-checkouts-pruned: two ci runs at two commits leave only the second commit's checkout",
       %{tmp_dir: dir} do
    {main, first, second} = repo(dir)
    stand_in()

    assert Checkout.ci(main, first, nil) == :green
    assert Checkout.ci(main, second, nil) == :green

    assert File.ls!(ci_dir(main)) == [second]
    refute listed(main) =~ first
    assert listed(main) =~ Path.join(ci_dir(main), second)

    # A later ci run at a new commit still works, and leaves only its own.
    assert Checkout.ci(main, first, nil) == :green
    assert File.ls!(ci_dir(main)) == [first]
    refute listed(main) =~ Path.join(ci_dir(main), second)
  end

  test "ci-checkouts-pruned: a ci checkout whose run is still going is kept", %{tmp_dir: dir} do
    {main, first, second} = repo(dir)
    test = self()

    # The first commit's run holds in its `just` until the test lets it go.
    stand_in(fn
      "just", _args, opts ->
        if String.contains?(opts[:cd], first) do
          send(test, {:running, self()})
          receive do: (:go -> nil)
        end

      _command, _args, _opts ->
        nil
    end)

    going = Task.async(fn -> Checkout.ci(main, first, nil) end)
    assert_receive {:running, runner}, 5_000

    assert Checkout.ci(main, second, nil) == :green
    assert File.dir?(Path.join(ci_dir(main), first))
    assert listed(main) =~ first

    send(runner, :go)
    assert Task.await(going, 10_000) == :green
  end

  test "ci-checkouts-pruned: a failing removal is logged and still records the ci result",
       %{tmp_dir: dir} do
    {main, first, second} = repo(dir)

    # Removing the first commit's checkout fails.
    stand_in(fn
      "git", ["worktree", "remove" | rest], _opts ->
        if String.ends_with?(List.last(rest), first), do: {"fatal: cannot remove", 128}

      _command, _args, _opts ->
        nil
    end)

    assert Checkout.ci(main, first, nil) == :green

    log =
      capture_log(fn ->
        assert Checkout.ci(main, second, nil) == :green
      end)

    assert log =~ "fatal: cannot remove"
    assert log =~ first

    ci_last = Path.join(Path.dirname(ci_dir(main)), "ci-last")
    assert %{"commit" => ^second, "failures" => []} = Jason.decode!(File.read!(ci_last))
  end
end
