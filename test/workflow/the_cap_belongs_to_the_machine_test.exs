defmodule Workflow.TheCapBelongsToTheMachineTest do
  # Not async: the works directory and the run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()

    was =
      for key <- [:manager, :works_dir, :machine_dir, :agents_run],
          do: {key, Application.fetch_env(:workflow, key)}

    # No manager turns and no server: the hand_in tool is called directly.
    Application.delete_env(:workflow, :manager)
    # One machine, in the test's own folder: never the real ~/.workflow.
    Application.put_env(:workflow, :machine_dir, Path.join(dir, "machine"))

    test = self()

    # A fake agent: it says it is at a work, and stays at it.
    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:agent, step.name, work["id"]})
      receive do: (:never -> {%{}, nil})
    end)

    on_exit(fn ->
      Workflow.Tellings.quiet()

      # Kept as it was, `machine_dir: false` included: never the real ~/.workflow.
      for {key, value} <- was do
        case value do
          {:ok, value} -> Application.put_env(:workflow, key, value)
          :error -> Application.delete_env(:workflow, key)
        end
      end
    end)

    :ok
  end

  defp git!(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(out)
  end

  # A project in its own folder: its repository, its works directory and its cap.
  defp project(dir, name, cap) do
    repo = Path.join([dir, name, "repo"])
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

    manager = %{
      "repo" => repo,
      "project" => "proj",
      "agents" => %{"coder" => %{"provider" => "claude-code"}},
      "cap" => cap
    }

    tools = Workflow.Manager.tools(manager)

    %{
      works: Path.join([dir, name, "works"]),
      hand_in: Enum.find(tools, &(&1.name == "hand_in")).execute,
      stop: Enum.find(tools, &(&1.name == "stop")).execute
    }
  end

  # Acts as the project's loop: its works are kept in its own works directory.
  defp as(%{works: works}), do: Application.put_env(:workflow, :works_dir, works)

  defp issue(id), do: %{"kind" => "issue", "id" => id, "text" => "Fault #{id}."}

  defp started(project, id) do
    as(project)
    assert {:ok, said} = project.hand_in.(issue(id), %{})
    refute said =~ "Refused"
    assert_receive {:agent, "fix", ^id}, 15_000
  end

  defp refused(project, id, cap) do
    as(project)
    assert {:ok, said} = project.hand_in.(issue(id), %{})
    assert said =~ "Refused"
    assert said =~ "at the cap of #{cap}"
    refute File.exists?(Path.join(project.works, "#{id}.json"))
    refute_receive {:agent, _step, ^id}, 200
  end

  test "the-cap-belongs-to-the-machine: criteria 1 and 2, two projects on one machine with a cap of 2 never run more than 2 works between them, and a freed slot takes the other's waiting work",
       %{tmp_dir: dir} do
    a = project(dir, "a", 2)
    b = project(dir, "b", 2)

    # One work running in each project: the machine's two slots are full.
    started(a, "a1")
    started(b, "b1")

    # Criterion 1: neither project starts a third, though each runs only one.
    refused(b, "b2", 2)
    refused(a, "a2", 2)

    # Criterion 2: a's work ends, and b's waiting work takes the freed slot.
    as(a)
    assert {:ok, _said} = a.stop.(%{"id" => "a1", "kind" => "issue"}, %{})
    refute File.exists?(Path.join(a.works, "a1.json"))

    started(b, "b2")

    # The slot is taken again: the machine is full once more.
    refused(a, "a3", 2)
  end

  test "the-cap-belongs-to-the-machine: criterion 3, a machine running one project keeps its configured cap",
       %{tmp_dir: dir} do
    a = project(dir, "a", 3)

    for id <- ["a1", "a2", "a3"], do: started(a, id)
    refused(a, "a4", 3)
  end

  test "the-cap-belongs-to-the-machine: the projects agree on the smallest cap any of them names",
       %{tmp_dir: dir} do
    a = project(dir, "a", 5)
    b = project(dir, "b", 2)

    started(a, "a1")
    started(b, "b1")
    refused(a, "a2", 2)
  end
end
