defmodule Workflow.CiBlamePerLandingTest do
  # Not async: the command a checkout runs is swapped for the whole application.
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Checkout

  @failing %{
    "level" => "error",
    "message" => %{"text" => "test it breaks (ATest)\nExpected truthy, got false"},
    "locations" => [
      %{"physicalLocation" => %{"artifactLocation" => %{"uri" => "test/a_test.exs"}}}
    ]
  }

  # Three commits, each the next one's parent, by real git: a green base, the
  # first landing (which breaks ci) and the second landing on top of it (which
  # still carries that break). The `ci` recipe marks where it ran.
  defp repo(dir) do
    main = Path.join(dir, "main")
    marks = Path.join(dir, "marks")
    File.mkdir_p!(main)

    File.write!(Path.join(main, "justfile"), """
    ci dir:
        echo "$(pwd)" >> "#{marks}"
        if [ -f broken ]; then cp fail.sarif "{{dir}}/exunit.sarif"; exit 1; fi
    """)

    sarif = %{
      "version" => "2.1.0",
      "runs" => [%{"tool" => %{"driver" => %{"name" => "exunit"}}, "results" => [@failing]}]
    }

    File.write!(Path.join(main, "fail.sarif"), Jason.encode!(sarif))

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: main, stderr_to_stdout: true)
      String.trim(out)
    end

    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.name", "t"])
    git.(["config", "user.email", "t@example.com"])
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "base"])
    base = git.(["rev-parse", "HEAD"])
    File.write!(Path.join(main, "broken"), "")
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "first landing"])
    first = git.(["rev-parse", "HEAD"])
    File.write!(Path.join(main, "other"), "")
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "second landing"])
    second = git.(["rev-parse", "HEAD"])
    git_dir = git.(~w(rev-parse --path-format=absolute --git-common-dir))

    %{main: main, marks: marks, git_dir: git_dir, base: base, first: first, second: second}
  end

  defp ran_at(%{marks: marks}, commit) do
    case File.read(marks) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.count(&(&1 =~ commit))
      _none -> 0
    end
  end

  test "ci-blame-per-landing: criteria 1 and 2 - two close landings, the second's ci ending first, each red blamed on the landing whose commit it ran on, neither result overwritten",
       %{tmp_dir: dir} do
    repo = repo(dir)
    test = self()

    # The first landing's run holds in its `just` until the test lets it go.
    Application.put_env(:workflow, :cmd, fn command, args, opts ->
      if command == "just" and args == ["--show", "ci"] and opts[:cd] =~ repo.first do
        send(test, {:running, self()})
        receive do: (:go -> nil)
      end

      System.cmd(command, args, opts)
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    assert Checkout.ci(repo.main, repo.base, nil) == :green

    first = Task.async(fn -> Checkout.ci(repo.main, repo.first, nil) end)
    assert_receive {:running, runner}, 5_000

    # The second landing's ci runs (twice: it is red) while the first's is held.
    second = Task.async(fn -> Checkout.ci(repo.main, repo.second, nil) end)
    Enum.find(1..200, fn _ -> ran_at(repo, repo.second) >= 2 or (Process.sleep(50) && false) end)
    assert ran_at(repo, repo.second) == 2
    early = Task.yield(second, 1_000)

    send(runner, :go)
    first = Task.await(first, 20_000)
    second = if early, do: elem(early, 1), else: Task.await(second, 20_000)

    # The break came with the first landing: it is the first's, not the second's.
    assert {:new, %{"status" => "failed"}} = first
    assert second == :known

    # Each result is kept by the commit it ran on.
    last = Jason.decode!(File.read!(Path.join([repo.git_dir, "workflow", "ci-last"])))
    runs = Map.new(last["runs"], &{&1["commit"], &1["failures"]})
    assert runs[repo.base] == []
    assert [["exunit", "test/a_test.exs", _text]] = runs[repo.first]
    assert runs[repo.second] == runs[repo.first]
  end
end
