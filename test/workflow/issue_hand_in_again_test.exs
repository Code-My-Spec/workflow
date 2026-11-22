defmodule Workflow.IssueHandInAgainTest do
  # Not async: the manager and its run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

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
      "agents" => %{"coder" => %{"provider" => "claude-code"}}
    })

    test = self()

    # An agent handed a work says so, and stays at it.
    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:agent, step.name, work["id"], work["text"]})
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

  defp works, do: Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json"))

  test "second-hand-in-keeps-the-first-text: an issue handed in again with different text is refused as a journey is, its file keeps the first text and nothing starts; with the same text it resumes",
       %{repo: repo, hand_in: hand_in} do
    first = %{"kind" => "issue", "id" => "i1", "text" => "Fault: the first direction."}
    file = Path.join([repo, "proj", "issues", "i1.yml"])

    # Recorded, and its work running with its coder at it.
    assert {:ok, _said} = hand_in.execute.(first, %{})
    assert_receive {:agent, "fix", "i1", "Fault: the first direction."}, 15_000
    recorded = File.read!(file)
    assert recorded =~ "the first direction"
    in_flight = works()
    log = git(repo, ~w(log --format=%H))

    # Handed in again with different text: refused, saying the text differs.
    again = Map.put(first, "text", "Fault: a new direction.")
    assert {:ok, refused} = hand_in.execute.(again, %{})
    assert refused =~ ~r/^Refused: /
    assert refused =~ ~r/differs from the recorded file/
    assert refused =~ ~r/as a journey/
    assert refused =~ "proj/issues/i1.yml"

    # The recorded file keeps the first text, and no work started or resumed.
    assert File.read!(file) == recorded
    assert git(repo, ~w(log --format=%H)) == log
    assert git(repo, ~w(status --porcelain)) == ""
    refute_receive {:agent, _step, _id, _text}, 500
    assert works() == in_flight

    # Handed in again with the same text: it resumes, as it does today.
    assert {:ok, said} = hand_in.execute.(first, %{})
    assert said =~ ~r/^i1: on fix \(coder\)/
    assert File.read!(file) == recorded
  end
end
