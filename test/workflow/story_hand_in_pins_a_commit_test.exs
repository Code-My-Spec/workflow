defmodule Workflow.StoryHandInPinsACommitTest do
  # Not async: the manager and its run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  @path "proj/.code_my_spec/stories/s1.yml"

  # A story as the person's chat writes it, by hand.
  defp story(said, more \\ "") do
    """
    # written by the chat
    id: k3f9a2qw
    title: Invite a teammate
    workflow: team-setup
    story: >
      #{said}
    rules:
      - rule: Only an owner may invite.
        id: 7hd2k3pz
        scenarios:
          - happy: An owner invites by email and the invite is sent.
            id: x9m4c8tb
    #{more}\
    """
  end

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    origin = Path.join(dir, "origin.git")
    repo = Path.join(dir, "repo")
    chat = Path.join(dir, "chat")
    File.mkdir_p!(origin)
    git(origin, ~w(init --bare -b main))

    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")
    File.write!(Path.join(repo, "justfile"), "copy-setup:\n\ncopy-teardown:\n")

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial),
          ["remote", "add", "origin", origin],
          ~w(push -q origin main)
        ],
        do: git(repo, args)

    git(dir, ["clone", "-q", origin, chat])
    git(chat, ~w(config user.email chat@example.com))
    git(chat, ~w(config user.name Chat))

    was = for key <- [:manager, :works_dir], do: {key, Application.get_env(:workflow, key)}
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => repo,
      "project" => "proj",
      "agents" => %{"qa" => %{"provider" => "claude-code"}}
    })

    test = self()

    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:agent, step, work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)

      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Workflow.Manager.tell("go")
    assert_receive {:tools, tools}, 5_000
    tool = fn name -> Enum.find(tools, &(&1.name == name)) end

    %{repo: repo, chat: chat, tool: tool}
  end

  defp git(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(out)
  end

  # Written and committed where `cd` is, pushed when it is the chat's clone: its sha.
  defp commit(cd, files, push? \\ true) do
    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(cd, path)))
      File.write!(Path.join(cd, path), content)
    end

    git(cd, ~w(add -A))
    git(cd, ["commit", "-q", "-m", "the chat wrote a story"])
    if push?, do: git(cd, ~w(push -q origin main))
    git(cd, ~w(rev-parse HEAD))
  end

  defp hand_in(tool, input), do: tool.("hand_in").execute.(input, %{})

  test "story-hand-in-pins-a-commit: criterion 1 - a story is read from .code_my_spec/stories/<id>.yml first, and from stories/<id>.yml only when the first does not exist",
       %{tmp_dir: dir, repo: repo, tool: tool} do
    # StoryFile itself, in a plain folder.
    root = Path.join(dir, "plain")
    work = %{"kind" => "story", "id" => "s9", "project" => "proj"}
    File.mkdir_p!(Path.join(root, "proj/stories"))
    File.write!(Path.join(root, "proj/stories/s9.yml"), "title: Old place\n")
    assert {:ok, %{"title" => "Old place"}} = Workflow.StoryFile.recorded(work, root)
    assert Workflow.StoryFile.located(work, root) == "proj/stories/s9.yml"

    File.mkdir_p!(Path.join(root, "proj/.code_my_spec/stories"))
    File.write!(Path.join(root, "proj/.code_my_spec/stories/s9.yml"), "title: New place\n")
    assert {:ok, %{"title" => "New place"}} = Workflow.StoryFile.recorded(work, root)
    assert Workflow.StoryFile.located(work, root) == "proj/.code_my_spec/stories/s9.yml"

    # Handed in by id: the new place wins over the old one at the same commit.
    commit(
      repo,
      [
        {@path, story("As an owner I want the new place.")},
        {"proj/stories/s1.yml", story("As an owner I want the old place.")},
        {"proj/stories/s2.yml", story("As an owner I want an old project.")}
      ],
      false
    )

    assert {:ok, _said} = hand_in(tool, %{"kind" => "story", "id" => "s1"})
    assert_receive {:agent, _step, work}, 5_000
    assert work["story"] =~ "the new place"
    assert work["story_path"] == @path

    # With no new file, the old one is read.
    assert {:ok, _said} = hand_in(tool, %{"kind" => "story", "id" => "s2"})
    assert_receive {:agent, _step, work}, 5_000
    assert work["story"] =~ "an old project"
    assert work["story_path"] == "proj/stories/s2.yml"
  end

  test "story-hand-in-pins-a-commit: criterion 2 - a hand-in at a sha reads the story at that commit of the fetched main copy, not the branch's later head; a sha with no commit or no story is refused saying which",
       %{repo: repo, chat: chat, tool: tool} do
    base = git(repo, ~w(rev-parse HEAD))
    old = commit(chat, [{@path, story("As an owner I want the first text.")}])
    _new = commit(chat, [{@path, story("As an owner I want the moved-on text.")}])

    # Neither commit is in the main copy until it is fetched.
    assert {:ok, said} = hand_in(tool, %{"kind" => "story", "id" => "s1", "at" => old})
    refute said =~ "Refused:"
    assert_receive {:agent, step, work}, 5_000

    assert work["story_at"] == old
    assert work["story"] =~ "the first text"
    refute work["story"] =~ "moved-on"
    assert Workflow.Agents.message(step, work, []) =~ "git show #{old}:#{@path}"

    assert {:ok, refused} =
             hand_in(tool, %{"kind" => "story", "id" => "s2", "at" => "deadbeef1234"})

    assert refused =~ "Refused: there is no commit deadbeef1234"

    assert {:ok, refused} = hand_in(tool, %{"kind" => "story", "id" => "s2", "at" => base})
    assert refused =~ "Refused: no story s2 is recorded at commit #{base}"
    assert refused =~ "proj/.code_my_spec/stories/s2.yml nor proj/stories/s2.yml"
    refute_receive {:agent, _step, _work}, 300
  end

  test "story-hand-in-pins-a-commit: criterion 3 - a hand-in with no at reads the story at the main copy's HEAD and records that HEAD's sha",
       %{repo: repo, tool: tool} do
    head = commit(repo, [{@path, story("As an owner I want it at HEAD.")}], false)

    assert {:ok, _said} = hand_in(tool, %{"kind" => "story", "id" => "s1"})
    assert_receive {:agent, _step, work}, 5_000
    assert work["story_at"] == head
    assert work["story"] =~ "at HEAD"

    kept = Workflow.Checkout.kept(repo <> "-s1", "s1")
    assert kept["story_at"] == head
  end

  test "story-hand-in-pins-a-commit: criterion 4 - a story with open questions at that commit is refused naming them, unless go: true",
       %{chat: chat, tool: tool} do
    questions = "questions:\n  - Can an owner cancel an invite?\n  - Do invites expire?\n"
    sha = commit(chat, [{@path, story("As an owner I want to invite.", questions)}])

    assert {:ok, refused} = hand_in(tool, %{"kind" => "story", "id" => "s1", "at" => sha})
    assert refused =~ "Refused"
    assert refused =~ "Can an owner cancel an invite?"
    assert refused =~ "Do invites expire?"
    refute_receive {:agent, _step, _work}, 300

    assert {:ok, said} =
             hand_in(tool, %{"kind" => "story", "id" => "s1", "at" => sha, "go" => true})

    refute said =~ "Refused:"
    assert_receive {:agent, _step, work}, 5_000
    assert work["story_at"] == sha
  end

  test "story-hand-in-pins-a-commit: criterion 5 - a newer sha while the first is in flight queues <story>-<short sha>, started once the first is stopped with the diff in its note; the same sha again is refused",
       %{chat: chat, tool: tool} do
    old = commit(chat, [{@path, story("As an owner I want to invite.")}])

    grown =
      story("As an owner I want to invite.") <>
        "      - fails: A member tries to invite and is told only owners can.\n" <>
        "        id: r5w2n7qa\n"

    new = commit(chat, [{@path, grown}])
    short = String.slice(new, 0, 7)

    assert {:ok, _said} = hand_in(tool, %{"kind" => "story", "id" => "s1", "at" => old})
    assert_receive {:agent, _step, %{"id" => "s1"}}, 5_000

    assert {:ok, queued} = hand_in(tool, %{"kind" => "story", "id" => "s1", "at" => new})
    assert queued =~ "s1-#{short}"
    assert queued =~ "queued behind s1"
    refute_receive {:agent, _step, _work}, 300

    for sha <- [new, old] do
      assert {:ok, refused} = hand_in(tool, %{"kind" => "story", "id" => "s1", "at" => sha})
      assert refused =~ "Refused"
      assert refused =~ "duplicate"
    end

    # The first stopped: the queued work starts, told the difference.
    assert {:ok, _stopped} = tool.("stop").execute.(%{"id" => "s1", "kind" => "story"}, %{})
    assert_receive {:agent, step, %{"id" => id} = work}, 10_000
    assert id == "s1-#{short}"
    assert work["story_from"] == old
    assert work["story_at"] == new

    note = Workflow.Agents.message(step, work, [])
    assert note =~ "the difference between #{old} and #{new}"
    assert note =~ "`git diff #{old}..#{new} -- #{@path}`"
    assert note =~ "+      - fails: A member tries to invite and is told only owners can."
  end

  test "story-hand-in-pins-a-commit: criterion 6 - a hand-in naming an existing story file commits nothing; one carrying its text still commits 'the story as handed in'",
       %{repo: repo, tool: tool} do
    head = commit(repo, [{@path, story("As an owner I want to invite.")}], false)

    assert {:ok, _said} = hand_in(tool, %{"kind" => "story", "id" => "s1"})
    assert_receive {:agent, _step, %{"id" => "s1"}}, 5_000

    assert git(repo, ~w(rev-parse HEAD)) == head
    assert git(repo <> "-s1", ["rev-list", "#{head}..HEAD"]) == ""

    full = %{
      "kind" => "story",
      "id" => "s2",
      "title" => "Leave a team",
      "story" => "As a member I want to leave a team.",
      "rules" => [%{"rule" => "Anyone may leave.", "scenarios" => [%{"happy" => "They leave."}]}]
    }

    assert {:ok, _said} = hand_in(tool, full)
    assert_receive {:agent, _step, %{"id" => "s2"}}, 5_000

    assert git(repo <> "-s2", ["log", "--format=%s", "#{head}..HEAD"]) ==
             "story s2: the story as handed in"
  end
end
