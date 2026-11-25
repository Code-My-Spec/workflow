defmodule Workflow.AJourneyIsDoneOnlyWhenItsWalkPassesTest do
  # Not async: the command runner is the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Journey

  # A fake walk: the checkout is at tree `tree` in the git directory `dir`, and the
  # project's `just run` (the journey's walk) exits `status` saying `output`.
  # No real git, browser or app.
  defp fake_walk(dir, tree, status, output) do
    test = self()

    Application.put_env(:workflow, :cmd, fn command, args, _opts ->
      case {command, args} do
        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} ->
          {dir <> "\n", 0}

        {"git", ["rev-parse", "HEAD^{tree}"]} ->
          {"#{tree}\n", 0}

        {"just", [recipe, _analysis_dir]} ->
          send(test, {:walked, recipe})
          {output, status}
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)
  end

  # A journey at tree "h" with every step of its workflow already done, and `found` too.
  defp snapshot(found) do
    %{
      id: "j1",
      head: "h",
      main: "trunk",
      stages: ["the user signs up"],
      named: [1],
      results: %{
        "h" =>
          Map.merge(
            %{
              "run" => %{"status" => "passed"},
              "certify" => %{"status" => "passed"},
              "review" => %{"status" => "pass"},
              "demo" => %{"status" => "passed"},
              "approve" => %{"status" => "approve"},
              "promote" => %{"status" => "promoted"},
              "ci" => %{"verdict" => "green"}
            },
            found
          )
      }
    }
  end

  @work %{"root" => "/root", "project" => nil, "id" => "j1"}

  # Its last step done, the journey runs its walk as the verify, and what the walk
  # found is recorded as the verify's result.
  defp verify(dir, status, output) do
    fake_walk(dir, "t1", status, output)
    assert %{name: "verify", actor: :system} = Workflow.current(Journey, snapshot(%{}))

    result = Workflow.Template.perform(Journey, "verify", @work, snapshot(%{}))
    assert_received {:walked, "run"}
    Workflow.current(Journey, snapshot(%{"verify" => result}))
  end

  test "journey-verify-is-a-workflow-verify: criterion 1 a journey whose walk fails at its verify step does not land, and its note carries the walk's failure",
       %{tmp_dir: dir} do
    assert %{name: "verify", stop: true, note: note} =
             verify(dir, 1, "stage 1: no flash after Sign up")

    assert note =~ "stage 1: no flash after Sign up"
  end

  test "journey-verify-is-a-workflow-verify: criterion 2 a journey whose walk passes at its verify step lands as done",
       %{tmp_dir: dir} do
    assert verify(dir, 0, "1 test, 0 failures") == nil
  end
end
