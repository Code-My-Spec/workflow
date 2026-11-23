defmodule Workflow.AJourneyWithoutStagesStopsNotCrashesTest do
  # Not async: the manager and its run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  @journey_note "this journey has no stages; hand it in again with its stages"
  @story_note "this story has no criteria; hand it in again with its criteria"

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    origin = Path.join(dir, "origin.git")
    repo = Path.join(dir, "repo")
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
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))

    %{repo: repo, hand_in: hand_in}
  end

  defp git(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(out)
  end

  defp nothing_started(repo, id) do
    refute_receive {:agent, _pid, _work}, 300
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []
    assert Path.wildcard(Path.join([Workflow.Run.works_dir(), "queued", "*.json"])) == []
    refute File.exists?(repo <> "-" <> id)
    assert git(repo, ~w(status --porcelain)) == ""
  end

  test "a-journey-without-stages-stops-not-crashes: criterion 1 - a journey hand-in with no stages is refused naming them, and nothing is started",
       %{repo: repo, hand_in: hand_in} do
    commits = git(repo, ~w(rev-list --count HEAD))

    for stages <- [nil, []] do
      input =
        %{"kind" => "journey", "id" => "j1", "title" => "Buy a book", "text" => "Buy one."}
        |> then(&if(stages, do: Map.put(&1, "stages", stages), else: &1))

      assert {:ok, refused} = hand_in.execute.(input, %{})
      assert refused =~ ~r/refused/i
      assert refused =~ "no stages"
      assert refused =~ "Nothing was started."
    end

    nothing_started(repo, "j1")
    assert git(repo, ~w(rev-list --count HEAD)) == commits
  end

  test "a-journey-without-stages-stops-not-crashes: criterion 2 - a story hand-in with no criteria is refused naming them, and nothing is started or recorded",
       %{repo: repo, hand_in: hand_in} do
    # A story with no rules, committed to the main copy, handed in by its id alone.
    path = Path.join(repo, "proj/.code_my_spec/stories/s1.yml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "id: k3f9a2qw\ntitle: Invite a teammate\nstory: >\n  An owner invites.\n")
    git(repo, ~w(add -A))
    git(repo, ["commit", "-q", "-m", "a story with no rules"])
    git(repo, ~w(push -q origin main))
    commits = git(repo, ~w(rev-list --count HEAD))

    inputs = [
      # The old way, with text and no criteria, or an empty list.
      %{"kind" => "story", "id" => "s1", "text" => "Invite a teammate."},
      %{"kind" => "story", "id" => "s1", "text" => "Invite a teammate.", "criteria" => []},
      # The story's shape, with no rules or no scenarios.
      %{"kind" => "story", "id" => "s1", "title" => "Invite", "story" => "An owner invites."},
      %{"kind" => "story", "id" => "s1", "title" => "Invite", "story" => "x", "rules" => []},
      # By its id alone, read from its file, with or without `at`.
      %{"kind" => "story", "id" => "s1"},
      %{"kind" => "story", "id" => "s1", "at" => git(repo, ~w(rev-parse HEAD))}
    ]

    for input <- inputs do
      assert {:ok, refused} = hand_in.execute.(input, %{})
      assert refused =~ ~r/refused/i, inspect(input)
      assert refused =~ "no criteria", inspect(input)
      assert refused =~ "Nothing was started.", inspect(input)
    end

    nothing_started(repo, "s1")
    assert git(repo, ~w(rev-list --count HEAD)) == commits
  end

  # A work in flight, written into its works file as the live one was: with no
  # stages (or criteria) at all, or an empty list.
  defp in_flight(dir, kind, id, parts) do
    root = Path.join(dir, "checkout-#{id}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "hello\n")

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -q -m initial)
        ],
        do: git(root, args)

    work =
      %{"kind" => kind, "id" => id, "root" => root, "title" => "Buy a book", "text" => "Buy."}
      |> Map.merge(parts)

    File.mkdir_p!(Workflow.Run.works_dir())
    File.write!(Path.join(Workflow.Run.works_dir(), "#{id}.json"), Jason.encode!(work))
    work
  end

  test "a-journey-without-stages-stops-not-crashes: criterion 3 - a work in flight with no stages or criteria is stopped with its note when it resumes, not crashed",
       %{tmp_dir: dir} do
    cases = [
      {"journey", "j1", %{}, @journey_note},
      {"journey", "j2", %{"stages" => []}, @journey_note},
      {"story", "s1", %{}, @story_note},
      {"story", "s2", %{"criteria" => []}, @story_note}
    ]

    works = for {kind, id, parts, note} <- cases, do: {in_flight(dir, kind, id, parts), note}

    assert :ok = Workflow.Run.resume()

    for {%{"id" => id, "root" => root}, note} <- works do
      assert %{"step" => "specify", "reason" => reason} = Workflow.Checkout.stopped(root, id)
      assert reason == "stopped: " <> note
    end

    refute_receive {:agent, _pid, _work}, 300
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []
  end

  test "a-journey-without-stages-stops-not-crashes: criterion 4 - look at such a work answers with its stopped state and note",
       %{tmp_dir: dir} do
    work = in_flight(dir, "journey", "j1", %{})
    story = in_flight(dir, "story", "s1", %{"criteria" => []})

    # Looked at before it runs: the note, not a crash.
    for {w, note} <- [{work, @journey_note}, {story, @story_note}] do
      asked = Map.take(w, ["kind", "id", "root"])
      assert %{step: "specify", note: ^note, done: false} = Workflow.Run.look(asked)
    end

    Workflow.Run.resume()

    for {w, note} <- [{work, @journey_note}, {story, @story_note}] do
      asked = Map.take(w, ["kind", "id", "root"])

      assert %{step: "specify", note: ^note, stopped: %{"reason" => reason}} =
               Workflow.Run.look(asked)

      assert reason =~ note
    end
  end
end
