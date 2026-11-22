defmodule Workflow.CiRetriesTest do
  # Not async: the manager's settings are set for the whole application.
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Checkout

  defp sarif(results) do
    Jason.encode!(%{
      "version" => "2.1.0",
      "runs" => [%{"tool" => %{"driver" => %{"name" => "exunit"}}, "results" => results}]
    })
  end

  @failing %{
    "level" => "error",
    "message" => %{"text" => "test a flaky one (ATest)\nExpected truthy, got false"},
    "locations" => [
      %{
        "physicalLocation" => %{
          "artifactLocation" => %{"uri" => "test/a_test.exs"},
          "region" => %{"startLine" => 4}
        }
      }
    ]
  }

  # A repository, by real git, whose `ci` recipe fails with @failing in its SARIF and
  # whose `retry` recipe (unless `retry` is nil) exits `retry` with @failing in its
  # SARIF where it fails and none where it passes. Each recipe leaves a mark: its
  # name and the directory it ran in.
  defp repo(dir, retry) do
    main = Path.join(dir, "main")
    marks = Path.join(dir, "marks")
    File.mkdir_p!(main)

    justfile =
      """
      ci dir:
          echo "ci $(pwd)" >> "#{marks}"
          cp first.sarif "{{dir}}/exunit.sarif"
          exit 1
      """ <>
        if retry,
          do: """

          retry dir:
              echo "retry $(pwd)" >> "#{marks}"
              cp retry.sarif "{{dir}}/exunit.sarif"
              exit #{retry}
          """,
          else: ""

    File.write!(Path.join(main, "justfile"), justfile)
    File.write!(Path.join(main, "first.sarif"), sarif([@failing]))
    File.write!(Path.join(main, "retry.sarif"), sarif(if retry == 0, do: [], else: [@failing]))

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: main, stderr_to_stdout: true)
      String.trim(out)
    end

    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.name", "t"])
    git.(["config", "user.email", "t@example.com"])
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "first"])

    commit = git.(["rev-parse", "HEAD"])
    git_dir = git.(~w(rev-parse --path-format=absolute --git-common-dir))

    %{
      main: main,
      commit: commit,
      at: Path.join([git_dir, "workflow", "ci", commit]),
      analysis: Path.join([git_dir, "workflow", "analysis", git.(["rev-parse", "HEAD^{tree}"])]),
      marks: marks
    }
  end

  defp marks(%{marks: marks}), do: marks |> File.read!() |> String.split("\n", trim: true)

  # The run folders at the tree, oldest first.
  defp runs(%{analysis: analysis}) do
    analysis
    |> File.ls!()
    |> Enum.filter(&(&1 =~ ~r/^\d+$/))
    |> Enum.sort_by(&String.to_integer/1)
    |> Enum.map(&Path.join(analysis, &1))
  end

  # A manager with no agent: an inbox, where what it is told is kept.
  defp inbox(dir) do
    keys = [:manager, :works_dir, :recipients]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :manager, %{"repo" => "/nowhere/repo"})
    Application.delete_env(:workflow, :recipients)
  end

  # What the manager was told, waiting a little for the loop's background telling.
  defp told do
    Enum.find_value(1..20, [], fn _ ->
      case Workflow.Messages.unread("manager") do
        [] -> Process.sleep(50) && nil
        messages -> messages
      end
    end)
  end

  test "ci-retries-with-a-retry-recipe: criteria 1, 2 and 3 - a failing ci is followed by just retry in the same checkout, both runs kept side by side, the flake named to the manager",
       %{tmp_dir: dir} do
    inbox(dir)
    repo = repo(dir, 0)

    assert Checkout.ci(repo.main, repo.commit, nil) ==
             {:green, [%{"file" => "test/a_test.exs", "test" => "test a flaky one (ATest)"}]}

    # Retry, not ci again, in the very checkout ci ran in.
    assert marks(repo) == ["ci #{repo.at}", "retry #{repo.at}"]

    # Both runs' evidence, side by side, neither overwritten.
    assert [first, second] = runs(repo)
    assert [%{"file" => "test/a_test.exs"}] = Workflow.Sarif.failures(first)
    assert File.exists?(Path.join(second, "exunit.sarif"))
    assert Workflow.Sarif.failures(second) == []
    assert %{"recipe" => "ci", "exit" => 1} = Workflow.Sarif.meta(first)
    assert %{"recipe" => "ci", "ran" => "retry", "exit" => 0} = Workflow.Sarif.meta(second)

    assert [%{"text" => text}] = told()
    assert text =~ "flaky"
    assert text =~ "just retry"
    assert text =~ "test/a_test.exs: test a flaky one (ATest)"
    assert text =~ first
    assert text =~ second
  end

  test "ci-retries-with-a-retry-recipe: criterion 1 - with no retry recipe a failing ci runs ci again, as before",
       %{tmp_dir: dir} do
    repo = repo(dir, nil)

    assert {:new, %{"status" => "failed"}} = Checkout.ci(repo.main, repo.commit, nil)
    assert marks(repo) == ["ci #{repo.at}", "ci #{repo.at}"]
    assert [_first, _second] = runs(repo)
  end

  test "ci-retries-with-a-retry-recipe: criterion 4 - a failing retry leaves the tree red, both runs kept",
       %{tmp_dir: dir} do
    inbox(dir)
    repo = repo(dir, 1)

    assert {:new, %{"status" => "failed", "dir" => second}} =
             Checkout.ci(repo.main, repo.commit, nil)

    assert marks(repo) == ["ci #{repo.at}", "retry #{repo.at}"]
    assert [_first, ^second] = runs(repo)
    assert told() == []
  end
end
