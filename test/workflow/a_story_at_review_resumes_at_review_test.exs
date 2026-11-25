defmodule Workflow.AStoryAtReviewResumesAtReviewTest do
  use ExUnit.Case, async: true

  # What the loop found about the story at its tree "h": the story's tests ran
  # green and certify passed, and no review has been recorded. Nothing about the
  # step it was at is kept but these findings, read again on a restart.
  defp waiting_at_review do
    Workflow.current(Workflow.Story, %{
      id: "s1",
      head: "h",
      main: "trunk",
      criteria: ["the user logs in"],
      named: [1],
      results: %{
        "h" => %{
          "run" => %{"status" => "passed"},
          "by" => %{"step" => "work"},
          "certify" => %{"status" => "passed"}
        }
      }
    })
  end

  test "workflows-are-data: criterion 8 a story waiting at review resumes at review when the loop runs on workflow files" do
    # The loop's story workflow is a file now, and the story is still at review.
    assert {:ok, %{name: "story", file: file}} = Workflow.Workflows.load("story")
    assert File.regular?(file)

    assert %{name: "review", actor: :reviewer, note: note} = waiting_at_review()
    assert note =~ "Review the story"

    # Asked again, as a restart does, it is at the same step.
    assert %{name: "review"} = waiting_at_review()
  end
end
