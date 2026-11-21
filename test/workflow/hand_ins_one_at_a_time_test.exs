defmodule Workflow.HandInsOneAtATimeTest do
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Checkout

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  test "hand-ins-one-at-a-time: criterion 1 - two works handed in at the same moment both have their files written and committed in the main copy, and neither fails on the git index lock",
       %{tmp_dir: repo} do
    git!(repo, ~w(init -q))
    git!(repo, ~w(config user.email loop@example.com))
    git!(repo, ~w(config user.name loop))
    git!(repo, ~w(commit -q --allow-empty -m start))

    # Two at once collide only now and then, so several pairs are handed in.
    for round <- 1..15 do
      works = ["a#{round}", "b#{round}"]

      results =
        works
        |> Enum.map(fn id ->
          Task.async(fn ->
            Checkout.commit_files(
              repo,
              [{"issues/#{id}.yml", "id: #{id}\n"}],
              "issue #{id}: the issue as handed in"
            )
          end)
        end)
        |> Task.await_many(30_000)

      assert results == [:ok, :ok]

      for id <- works do
        assert git!(repo, ["log", "--format=%s", "--", "issues/#{id}.yml"]) ==
                 "issue #{id}: the issue as handed in\n"
      end
    end

    assert git!(repo, ~w(status --porcelain)) == ""
  end
end
