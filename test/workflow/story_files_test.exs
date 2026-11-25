defmodule Workflow.StoryFilesTest do
  # Not async: the command a checkout runs is swapped for the whole application.
  use ExUnit.Case

  @moduletag :tmp_dir

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  # A real repository on `main` with one commit, and a branch cut from it for the work.
  defp repo!(dir) do
    git!(dir, ~w(init -b main))
    git!(dir, ~w(config user.email test@example.com))
    git!(dir, ~w(config user.name Test))
    File.mkdir_p!(Path.join(dir, "proj"))
    File.write!(Path.join([dir, "proj", "README.md"]), "hello\n")
    git!(dir, ~w(add -A))
    git!(dir, ~w(commit -m initial))
    git!(dir, ~w(checkout -b story/s1))
  end

  test "story-files: criterion 1 - handing in a story commits stories/<id>.yml in its project directory as the work's first commit",
       %{tmp_dir: dir} do
    repo!(dir)

    work = %{
      "kind" => "story",
      "id" => "s1",
      "root" => dir,
      "project" => "proj",
      "text" => "A user can log in.",
      "criteria" => ["the user logs in", "the user logs out"]
    }

    Workflow.Run.step(work)

    [first | _] =
      git!(dir, ~w(log --reverse --format=%H main..HEAD)) |> String.split("\n", trim: true)

    assert git!(dir, ["show", "--name-only", "--format=", first]) == "proj/stories/s1.yml"

    yml = File.read!(Path.join([dir, "proj", "stories", "s1.yml"]))
    assert yml =~ "s1"
    assert yml =~ "story"
    assert yml =~ "A user can log in."
    assert yml =~ "the user logs in"
    assert yml =~ "the user logs out"
  end

  defp commits(dir),
    do: git!(dir, ~w(log --format=%H main..HEAD)) |> String.split("\n", trim: true)

  test "story-files: the file is readable, the text a block and each criterion a line of its own",
       %{tmp_dir: dir} do
    repo!(dir)

    work = %{
      "kind" => "story",
      "id" => "s1",
      "root" => dir,
      "project" => "proj",
      "text" => "A user can log in.\n\nWith a \"password\".",
      "criteria" => ["the user logs in", "the user logs out: and is gone"]
    }

    Workflow.Run.step(work)

    assert File.read!(Path.join([dir, "proj", "stories", "s1.yml"])) ==
             """
             id: "s1"
             kind: "story"
             text: |-
               A user can log in.

               With a "password".
             criteria:
               - "the user logs in"
               - "the user logs out: and is gone"
             """
  end

  test "story-files: a journey's file holds its stages, at the checkout's root with no project",
       %{tmp_dir: dir} do
    repo!(dir)

    work = %{
      "kind" => "journey",
      "id" => "j1",
      "root" => dir,
      "text" => "sign up",
      "stages" => ["the user signs up", "the user confirms"]
    }

    Workflow.Run.step(work)

    assert [first] = commits(dir)
    assert git!(dir, ["show", "--name-only", "--format=", first]) == "stories/j1.yml"

    yml = File.read!(Path.join([dir, "stories", "j1.yml"]))
    assert yml =~ "kind: \"journey\""
    assert yml =~ "stages:\n  - \"the user signs up\"\n  - \"the user confirms\"\n"
    refute yml =~ "criteria"
  end

  test "story-files: criterion 2 - handing in a journey commits stories/<id>.yml in its project directory as the work's first commit, holding its id, kind, text and stages",
       %{tmp_dir: dir} do
    repo!(dir)

    Workflow.Run.step(%{
      "kind" => "journey",
      "id" => "j1",
      "root" => dir,
      "project" => "proj",
      "text" => "A newcomer signs up.",
      "stages" => ["the user signs up", "the user confirms"]
    })

    [first | _] =
      git!(dir, ~w(log --reverse --format=%H main..HEAD)) |> String.split("\n", trim: true)

    assert git!(dir, ["show", "--name-only", "--format=", first]) == "proj/stories/j1.yml"

    yml = File.read!(Path.join([dir, "proj", "stories", "j1.yml"]))
    assert yml =~ "j1"
    assert yml =~ "journey"
    assert yml =~ "A newcomer signs up."
    assert yml =~ "the user signs up"
    assert yml =~ "the user confirms"
  end

  test "story-files: criterion 3 - handing in an issue writes no file and makes no commit for it",
       %{tmp_dir: dir} do
    repo!(dir)

    Workflow.Run.step(%{
      "kind" => "issue",
      "id" => "i1",
      "root" => dir,
      "project" => "proj",
      "text" => "saving crashes"
    })

    assert commits(dir) == []
    refute File.exists?(Path.join([dir, "proj", "stories"]))
    refute File.exists?(Path.join([dir, "stories"]))
    assert git!(dir, ~w(status --porcelain)) == ""
  end

  test "story-files: criterion 4 - stories/<id>.yml already there with the same content, handing the work in makes no new commit",
       %{tmp_dir: dir} do
    repo!(dir)

    work = %{
      "kind" => "story",
      "id" => "s1",
      "root" => dir,
      "project" => "proj",
      "text" => "A user can log in.",
      "criteria" => ["the user logs in"]
    }

    Workflow.Run.step(work)
    head = git!(dir, ~w(rev-parse HEAD))
    file = File.read!(Path.join([dir, "proj", "stories", "s1.yml"]))

    Workflow.Run.step(work)

    assert git!(dir, ~w(rev-parse HEAD)) == head
    assert length(commits(dir)) == 1
    assert File.read!(Path.join([dir, "proj", "stories", "s1.yml"])) == file
    assert git!(dir, ~w(status --porcelain)) == ""

    # Handed in again with a criterion more, the file changes and is committed again.
    Workflow.Run.step(%{work | "criteria" => ["the user logs in", "the user logs out"]})
    assert length(commits(dir)) == 2
  end

  test "story-files: a work handed in again with a review or an owner's decision writes no file" do
    story = %{"kind" => "story", "id" => "s1", "text" => "t", "criteria" => ["c"]}

    assert Workflow.StoryFile.path(story) == "stories/s1.yml"
    assert Workflow.StoryFile.path(Map.put(story, "demo", "approve")) == nil
    assert Workflow.StoryFile.path(Map.put(story, "review", "pass")) == nil
    assert Workflow.StoryFile.path(%{"kind" => "story", "id" => "s1"}) == nil
  end

  test "story-shape: criterion 1 - a story handed in with title, story, rules with scenarios, questions and a workflow is written to stories/<id>.yml in the shape given, in the work's first commit",
       %{tmp_dir: dir} do
    repo!(dir)

    Workflow.Run.step(%{
      "kind" => "story",
      "id" => "s1",
      "root" => dir,
      "project" => "proj",
      "title" => "Invite a teammate",
      "workflow" => "team-setup",
      "story" =>
        "As an account owner I want to invite a teammate by email so they can work in my project.",
      "rules" => [
        %{
          "rule" => "Only an owner may invite.",
          "scenarios" => [
            %{"happy" => "An owner invites by email and the invite is sent."},
            %{"fails" => "A member tries to invite and is told only owners can."}
          ]
        }
      ],
      "questions" => ["Can an owner cancel a sent invite?"]
    })

    [first | _] =
      git!(dir, ~w(log --reverse --format=%H main..HEAD)) |> String.split("\n", trim: true)

    # Written in the work's first commit.
    assert "proj/stories/s1.yml" in (git!(dir, ["show", "--name-only", "--format=", first])
                                     |> String.split("\n", trim: true))

    assert File.read!(Path.join([dir, "proj", "stories", "s1.yml"])) ==
             """
             title: Invite a teammate
             journey: team-setup
             story: >
               As an account owner I want to invite a teammate by email so they can work in my project.
             rules:
               - rule: Only an owner may invite.
                 scenarios:
                   - happy: An owner invites by email and the invite is sent.
                   - fails: A member tries to invite and is told only owners can.
             questions:
               - Can an owner cancel a sent invite?
             """
  end

  test "story-shape: criterion 4 - a story handed in the old way, with only text and criteria, is written to stories/<id>.yml as it is today",
       %{tmp_dir: dir} do
    repo!(dir)

    Workflow.Run.step(%{
      "kind" => "story",
      "id" => "s1",
      "root" => dir,
      "project" => "proj",
      "text" => "A user can log in.",
      "criteria" => ["the user logs in", "the user logs out"]
    })

    [first | _] =
      git!(dir, ~w(log --reverse --format=%H main..HEAD)) |> String.split("\n", trim: true)

    assert git!(dir, ["show", "--name-only", "--format=", first]) == "proj/stories/s1.yml"

    assert File.read!(Path.join([dir, "proj", "stories", "s1.yml"])) ==
             """
             id: "s1"
             kind: "story"
             text: |-
               A user can log in.
             criteria:
               - "the user logs in"
               - "the user logs out"
             """

    refute File.exists?(Path.join([dir, "proj", "workflows"]))
  end
end
