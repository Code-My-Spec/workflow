defmodule Workflow.StoryJourneyKeyTest do
  # A story names the persona's journey it is a step of as `journey:`. It was
  # `workflow:` before that word came to mean the steps a work runs through, so
  # stories already written that way keep working.
  use ExUnit.Case, async: true

  alias Workflow.StoryFile

  @story %{
    "kind" => "story",
    "id" => "s1",
    "title" => "Invite a teammate",
    "story" => "As an account owner I want to invite a teammate.",
    "rules" => [
      %{
        "rule" => "Only an owner may invite.",
        "scenarios" => [%{"happy" => "An owner invites by email and the invite is sent."}]
      }
    ],
    "questions" => []
  }

  test "a story handed in with journey is written with journey" do
    yml = StoryFile.yaml(Map.put(@story, "journey", "team-setup"))

    assert yml =~ "journey: team-setup\n"
    refute yml =~ "workflow:"
  end

  test "a story handed in with the older workflow key is written with journey" do
    yml = StoryFile.yaml(Map.put(@story, "workflow", "team-setup"))

    assert yml =~ "journey: team-setup\n"
    refute yml =~ "workflow:"
  end

  test "when both are given, journey wins and workflow is not written" do
    yml =
      StoryFile.yaml(@story |> Map.put("journey", "team-setup") |> Map.put("workflow", "old"))

    assert yml =~ "journey: team-setup\n"
    refute yml =~ "old"
  end

  test "a story counts as handed in with its shape when it carries only a journey" do
    work = %{"kind" => "story", "id" => "s1", "journey" => "team-setup"}

    assert StoryFile.path(work) == "stories/s1.yml"
  end

  @tag :tmp_dir
  test "a recorded story written with workflow is read back with its journey", %{tmp_dir: root} do
    path = Path.join([root, "stories", "s1.yml"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    title: Invite a teammate
    workflow: team-setup
    story: >
      As an account owner I want to invite a teammate.
    """)

    assert {:ok, fields} = StoryFile.recorded(%{"kind" => "story", "id" => "s1"}, root)
    assert fields["journey"] == "team-setup"
    refute Map.has_key?(fields, "workflow")
  end

  test "as_journey leaves a work with neither key alone" do
    assert StoryFile.as_journey(%{"id" => "s1"}) == %{"id" => "s1"}
  end
end
