defmodule Workflow.StoryIdsTest do
  # Not async: the manager and its run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  @alphabet "23456789abcdefghjkmnpqrstuvwxyz"

  setup do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)
  end

  defp git!(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    out
  end

  # A main copy in a temporary repo, the manager configured on it, and each agent
  # a fake that reports the work it was given and holds its turn.
  defp hand_in!(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")
    File.write!(Path.join(repo, "justfile"), "copy-setup:\n\ncopy-teardown:\n")

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git!(repo, args)

    was = for key <- [:manager, :works_dir], do: {key, Application.get_env(:workflow, key)}

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => repo,
      "project" => "proj",
      "agents" => %{"qa" => %{"provider" => "claude-code"}}
    })

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)

      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    hand_in =
      Enum.find(Workflow.Manager.tools(Workflow.Manager.configured()), &(&1.name == "hand_in"))

    {repo, hand_in}
  end

  defp story(ids) do
    %{
      "story_id" => ids[:story],
      "title" => "Invite a teammate",
      "story" => "As an account owner I want to invite a teammate.",
      "rules" => [
        %{
          "id" => ids[:rule],
          "rule" => "Only an owner may invite.",
          "scenarios" => [
            %{"id" => ids[:happy], "happy" => "An owner invites and the invite is sent."},
            %{"id" => ids[:fails], "fails" => "A member tries to invite and is refused."}
          ]
        }
      ]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.update!("rules", fn rules ->
      for rule <- rules do
        rule
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.update!("scenarios", fn scenarios ->
          Enum.map(scenarios, &Map.reject(&1, fn {_key, value} -> is_nil(value) end))
        end)
      end
    end)
  end

  @all [story: "k3f9a2qw", rule: "7hd2k3pz", happy: "x9m4c8tb", fails: "r5w2n7qa"]

  # The story recorded in the main copy, as a person or the chat agent wrote it.
  defp record!(repo, id, story) do
    file = Path.join([repo, "proj", "stories", "#{id}.yml"])
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Workflow.StoryFile.yaml(Map.put(story, "kind", "story")))
    git!(repo, ~w(add -A))
    git!(repo, ["commit", "-m", "story #{id}: recorded"])
  end

  defp nothing_started(repo, id) do
    refute_receive {:agent, _pid, _work}, 300
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []
    refute File.exists?(repo <> "-" <> id)
  end

  test "story-ids-are-required: criterion 1 - a story hand-in by id whose story, a rule or a scenario has no id is refused, naming each",
       %{tmp_dir: dir} do
    {repo, hand_in} = hand_in!(dir)

    record!(repo, "s1", story(Keyword.drop(@all, [:story, :rule, :fails])))

    assert {:ok, refused} = hand_in.execute.(%{"kind" => "story", "id" => "s1"}, %{})

    assert refused ==
             "Refused: story s1 cannot be handed in, these have no id: the story; " <>
               "rule 1 (\"Only an owner may invite.\"); " <>
               "scenario 2 of rule 1 (\"A member tries to invite and is refused.\"). " <>
               "The story, each rule and each scenario needs an id of its own (`id:`), 8 " <>
               "characters from #{@alphabet}. Nothing was started."

    # The scenario that has its id is not named.
    refute refused =~ "scenario 1"
    nothing_started(repo, "s1")
  end

  test "story-ids-are-required: criterion 2 - a story hand-in whose ids repeat within the story is refused, naming each repeated id",
       %{tmp_dir: dir} do
    {repo, hand_in} = hand_in!(dir)

    record!(repo, "s1", story(Keyword.merge(@all, rule: "k3f9a2qw", fails: "x9m4c8tb")))

    assert {:ok, refused} = hand_in.execute.(%{"kind" => "story", "id" => "s1"}, %{})
    assert refused =~ "Refused: story s1 cannot be handed in, these ids repeat: "
    assert refused =~ "k3f9a2qw (2 times)"
    assert refused =~ "x9m4c8tb (2 times)"
    refute refused =~ "have no id"
    nothing_started(repo, "s1")

    # Ids carried in a story's own text are kept as given, so repeated ones are refused too.
    carried =
      Map.merge(story(Keyword.put(@all, :fails, "x9m4c8tb")), %{"kind" => "story", "id" => "s2"})

    assert {:ok, refused} = hand_in.execute.(carried, %{})
    assert refused =~ "these ids repeat: x9m4c8tb (2 times)"
    nothing_started(repo, "s2")
  end

  test "story-ids-are-required: criterion 3 - a story hand-in carrying its text gets an id generated for the story, each rule and each scenario, written into its recorded file",
       %{tmp_dir: dir} do
    {repo, hand_in} = hand_in!(dir)

    # The second scenario's id is given, and kept.
    carried =
      Map.merge(story(Keyword.take(@all, [:fails])), %{"kind" => "story", "id" => "s1"})

    assert {:ok, said} = hand_in.execute.(carried, %{})
    refute said =~ "Refused"
    assert_receive {:agent, _agent, work}, 5_000

    %{"story_id" => story_id, "rules" => [%{"id" => rule_id, "scenarios" => [happy, fails]}]} =
      work

    assert fails["id"] == "r5w2n7qa"
    ids = [story_id, rule_id, happy["id"]]

    for id <- ids do
      assert id =~ ~r/^[#{@alphabet}]{8}$/
    end

    assert Enum.uniq(ids ++ ["r5w2n7qa"]) == ids ++ ["r5w2n7qa"]

    # The recorded file holds them, and reads back the same.
    yml = File.read!(Path.join([repo <> "-s1", "proj", "stories", "s1.yml"]))
    # An id that starts with a digit is written quoted, as YAML would read it otherwise.
    assert yml =~ ~r/\Aid: "?#{story_id}"?\n/
    assert yml =~ ~r/\n    id: "?#{rule_id}"?\n/
    assert yml =~ ~r/\n        id: "?#{happy["id"]}"?\n/
    assert yml =~ "        id: r5w2n7qa\n"

    assert {:ok, read} =
             Workflow.StoryFile.recorded(%{"id" => "s1", "project" => "proj"}, repo <> "-s1")

    assert read["story_id"] == story_id
    assert read["rules"] == work["rules"]
  end

  test "story-ids-are-required: criterion 4 - a work's agent brief shows each rule and each scenario with its id" do
    work = Map.merge(story(@all), %{"kind" => "story", "id" => "s1"})
    brief = Workflow.Agents.message(%{note: nil}, work, [])

    assert brief =~ "This work's own criteria (story k3f9a2qw), and no other story's:"

    assert brief =~
             "1. Only an owner may invite. An owner invites and the invite is sent. " <>
               "(rule 7hd2k3pz, scenario x9m4c8tb)"

    assert brief =~
             "2. Only an owner may invite. A member tries to invite and is refused. " <>
               "(rule 7hd2k3pz, scenario r5w2n7qa)"
  end

  test "story-ids-are-required: criterion 5 - a story file without ids is read for status and listing as today",
       %{tmp_dir: dir} do
    git!(dir, ~w(init -b main))
    bare = story([])
    file = Path.join([dir, "proj", "stories", "old.yml"])
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Workflow.StoryFile.yaml(Map.put(bare, "kind", "story")))

    assert {:ok, read} = Workflow.StoryFile.recorded(%{"id" => "old", "project" => "proj"}, dir)
    refute Map.has_key?(read, "story_id")
    assert read["rules"] == bare["rules"]

    assert Workflow.StoryFile.criteria(read) == [
             "Only an owner may invite. An owner invites and the invite is sent.",
             "Only an owner may invite. A member tries to invite and is refused."
           ]

    # Its brief lists its criteria as before, with no ids and no refusal.
    brief = Workflow.Agents.message(%{note: nil}, Map.put(read, "kind", "story"), [])

    assert brief =~
             "This work's own criteria, and no other story's:\n1. Only an owner may invite."

    refute brief =~ "Refused"
  end
end
