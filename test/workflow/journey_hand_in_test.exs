defmodule Workflow.JourneyHandInTest do
  # Not async: the manager and its run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  @recorded """
  name: Buy a book
  persona: Reader
  text: |
    A reader finds a book and buys it.
  stages:
    - "The reader searches for a book"
    - "The reader opens the book's page"
    - "The reader pays"
  """

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
    out
  end

  defp record_journey(repo) do
    File.mkdir_p!(Path.join([repo, "proj", "stories"]))
    File.write!(Path.join([repo, "proj", "stories", "j1.yml"]), @recorded)
    git(repo, ~w(add -A))
    git(repo, ["commit", "-m", "journey j1: the journey as recorded"])
  end

  defp nothing_started(repo) do
    refute_receive {:agent, _pid, _work}, 300
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []
    refute File.exists?(repo <> "-j1")
  end

  test "journey-without-stages-crashes: criterion 1 - a journey handed in by its id alone runs with its recorded stages and makes no second story-file commit",
       %{repo: repo, hand_in: hand_in} do
    record_journey(repo)

    assert {:ok, _said} = hand_in.execute.(%{"kind" => "journey", "id" => "j1"}, %{})
    assert_receive {:agent, _agent, work}, 5_000

    assert work["stages"] == [
             "The reader searches for a book",
             "The reader opens the book's page",
             "The reader pays"
           ]

    assert work["text"] == "A reader finds a book and buys it.\n"

    checkout = repo <> "-j1"

    journey_commits =
      git(checkout, ~w(log --format=%s))
      |> String.split("\n", trim: true)
      |> Enum.filter(&(&1 =~ "journey j1:"))

    assert journey_commits == ["journey j1: the journey as recorded"]
    assert File.read!(Path.join([checkout, "proj", "stories", "j1.yml"])) == @recorded
  end

  test "journey-without-stages-crashes: criterion 2 - a journey handed in with fields over a recorded file is refused, and the file is not changed",
       %{repo: repo, hand_in: hand_in} do
    record_journey(repo)

    input = %{
      "kind" => "journey",
      "id" => "j1",
      "title" => "Buy a book",
      "text" => "Mind the checkout page."
    }

    assert {:ok, refused} = hand_in.execute.(input, %{})
    assert refused =~ ~r/refused/i
    assert refused =~ ~r/by its id alone/
    assert refused =~ ~r/\btell\b/

    nothing_started(repo)
    assert File.read!(Path.join([repo, "proj", "stories", "j1.yml"])) == @recorded
    assert git(repo, ~w(status --porcelain)) == ""
  end

  test "journey-without-stages-crashes: criterion 3 - a journey handed in whole with no stages is refused at hand-in",
       %{repo: repo, hand_in: hand_in} do
    for stages <- [nil, []] do
      input =
        %{"kind" => "journey", "id" => "j1", "title" => "Buy a book", "text" => "Buy one."}
        |> then(&if(stages, do: Map.put(&1, "stages", stages), else: &1))

      assert {:ok, refused} = hand_in.execute.(input, %{})
      assert refused =~ ~r/refused/i
      assert refused =~ ~r/no stages/
    end

    nothing_started(repo)
  end
end
