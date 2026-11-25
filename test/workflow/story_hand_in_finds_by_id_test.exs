defmodule Workflow.StoryHandInFindsByIdTest do
  # Not async: the manager and its run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  # A story file named by its slug, holding its id inside.
  defp story(id, said) do
    """
    id: #{id}
    title: Workflows are data
    journey: build-and-land-work
    story: >
      #{said}
    rules:
      - rule: Each kind of work's steps come from a file.
        id: 7hd2k3pz
        scenarios:
          - happy: A new kind of work needs a file.
            id: x9m4c8tb
    """
  end

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

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
        do: git(repo, args)

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

    %{repo: repo, tool: tool}
  end

  defp git(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit(repo, files) do
    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(repo, path)))
      File.write!(Path.join(repo, path), content)
    end

    git(repo, ~w(add -A))
    git(repo, ["commit", "-q", "-m", "stories"])
    git(repo, ~w(rev-parse HEAD))
  end

  defp hand_in(tool, input), do: tool.("hand_in").execute.(input, %{})

  test "story-hand-in-finds-by-id: criterion 1 - handing in a story by id finds stories/<slug>.yml whose id: matches the id given",
       %{repo: repo, tool: tool} do
    head =
      commit(repo, [
        {"proj/stories/another-story.yml", story("b7c2m4nq", "As someone else I want another.")},
        {"proj/stories/workflows-are-data.yml", story("vckx9kjj", "As the runner I want data.")}
      ])

    assert {:ok, said} = hand_in(tool, %{"kind" => "story", "id" => "vckx9kjj"})
    refute said =~ "Refused:"
    assert_receive {:agent, _step, work}, 5_000
    assert work["id"] == "vckx9kjj"
    assert work["story"] =~ "I want data"
    assert work["story_path"] == "proj/stories/workflows-are-data.yml"
    assert work["story_at"] == head
  end

  test "story-hand-in-finds-by-id: criterion 2 - the same works for a story under .code_my_spec/stories/",
       %{repo: repo, tool: tool} do
    path = "proj/.code_my_spec/stories/workflows-are-data.yml"
    sha = commit(repo, [{path, story("vckx9kjj", "As the runner I want it pinned.")}])
    _later = commit(repo, [{path, story("vckx9kjj", "As the runner I moved on.")}])

    assert {:ok, said} = hand_in(tool, %{"kind" => "story", "id" => "vckx9kjj", "at" => sha})
    refute said =~ "Refused:"
    assert_receive {:agent, _step, work}, 5_000
    assert work["story"] =~ "I want it pinned"
    assert work["story_path"] == path
    assert work["story_at"] == sha
  end

  test "story-hand-in-finds-by-id: criterion 3 - a hand-in by an id no story file holds at that commit is refused, and nothing is started",
       %{repo: repo, tool: tool} do
    old = git(repo, ~w(rev-parse HEAD))

    commit(repo, [
      {"proj/stories/workflows-are-data.yml", story("vckx9kjj", "As the runner I want data.")}
    ])

    assert {:ok, refused} = hand_in(tool, %{"kind" => "story", "id" => "zzzz2222"})
    assert refused =~ "Refused: no story zzzz2222 is recorded at commit"

    # Held at HEAD, but not at the earlier commit.
    assert {:ok, refused} = hand_in(tool, %{"kind" => "story", "id" => "vckx9kjj", "at" => old})
    assert refused =~ "Refused: no story vckx9kjj is recorded at commit #{old}"

    refute_receive {:agent, _step, _work}, 300
    refute File.exists?(repo <> "-zzzz2222")
    refute File.exists?(repo <> "-vckx9kjj")
  end
end
