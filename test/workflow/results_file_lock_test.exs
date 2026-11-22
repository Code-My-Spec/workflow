defmodule Workflow.ResultsFileLockTest do
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Checkout

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  test "small-audit-fixes-in-the-loop: criterion 1 - two updates to the results file at the same time are both kept",
       %{tmp_dir: repo} do
    git!(repo, ~w(init -q))
    git!(repo, ~w(config user.email loop@example.com))
    git!(repo, ~w(config user.name loop))
    git!(repo, ~w(commit -q --allow-empty -m start))

    # Two at once collide only now and then, so several pairs are made.
    for round <- 1..30 do
      said = ["a#{round}", "b#{round}"]

      said
      |> Enum.map(fn line -> Task.async(fn -> Checkout.say(repo, "work", line) end) end)
      |> Task.await_many(30_000)

      assert Enum.sort(Checkout.heard(repo, "work")) == said
    end
  end

  test "small-audit-fixes-in-the-loop: criterion 3 - one now gives the time as ISO 8601 in UTC" do
    assert {:ok, _at, 0} = DateTime.from_iso8601(Checkout.now())
  end
end
