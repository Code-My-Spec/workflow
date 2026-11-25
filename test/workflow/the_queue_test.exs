defmodule Workflow.TheQueueTest do
  # Not async: the command a checkout runs, the agent, the manager, the machine
  # and where works in flight are kept, are app-wide.
  use ExUnit.Case

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    test = self()

    was =
      for key <- [
            :cmd,
            :works_dir,
            :machine_dir,
            :agents_run,
            :push,
            :manager,
            :manager_run,
            :recipients
          ],
          do: {key, Application.fetch_env(:workflow, key)}

    on_exit(fn ->
      # Kept as it was, `machine_dir: false` included: never the real ~/.workflow.
      for {key, value} <- was do
        case value do
          {:ok, value} -> Application.put_env(:workflow, key, value)
          :error -> Application.delete_env(:workflow, key)
        end
      end
    end)

    # Git is real; `just` is never run, and passes.
    Application.put_env(:workflow, :cmd, fn
      "just", _args, _opts -> {"", 0}
      command, args, opts -> System.cmd(command, args, opts)
    end)

    # No such remote: promote merges into the main copy and pushes nothing.
    Application.put_env(:workflow, :push, %{"remote" => "nowhere", "branch" => "main"})
    Application.delete_env(:workflow, :recipients)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      {:ok, %{text: "noted", messages: opts[:messages]}}
    end)

    # One machine, in the test's own folder: never the real ~/.workflow.
    Application.put_env(:workflow, :machine_dir, Path.join(dir, "machine"))

    # A coder says it is at work, and stays at it until told to go: then it
    # commits a fix, and the work goes on, lands and parks at ci, freeing its
    # slot. A reviewer passes.
    Application.put_env(:workflow, :agents_run, fn
      %{name: "review"}, _work ->
        {%{"status" => "pass"}, nil}

      %{name: "fix"}, %{"id" => id, "root" => root} ->
        send(test, {:fix, id, self()})
        receive(do: (:go -> :ok))
        file = "#{id}-#{System.unique_integer([:positive])}.txt"
        File.write!(Path.join(root, file), "fixed\n")
        git(root, ["add", file])
        git(root, ["commit", "-q", "-m", "#{id}: a fix"])
        {%{}, nil}
    end)

    :ok
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  # A project in its own folder, its works kept in its own works directory, with
  # the manager's tools for it.
  defp project(dir, name, cap) do
    repo = Path.join([dir, name, "repo"])
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README.md"), "hello\n")

    for args <- [
          ~w(init -q -b main),
          ~w(config user.email t@example.com),
          ~w(config user.name t),
          ~w(add -A),
          ~w(commit -q -m initial)
        ],
        do: git(repo, args)

    agent = %{"provider" => "claude-code"}

    manager = %{
      "agent" => agent,
      "repo" => repo,
      "agents" => %{"coder" => agent, "reviewer" => agent},
      "cap" => cap
    }

    tools = Workflow.Manager.tools(manager)

    %{
      manager: manager,
      works: Path.join([dir, name, "works"]),
      hand_in: Enum.find(tools, &(&1.name == "hand_in")).execute,
      stop: Enum.find(tools, &(&1.name == "stop")).execute
    }
  end

  # Acts as the project's loop.
  defp as(%{works: works, manager: manager}) do
    Application.put_env(:workflow, :works_dir, works)
    Application.put_env(:workflow, :manager, manager)
  end

  defp issue(id), do: %{"kind" => "issue", "id" => id, "text" => "Fault #{id}."}

  defp handed_in(project, id) do
    as(project)
    assert {:ok, said} = project.hand_in.(issue(id), %{})
    refute said =~ "Refused", said
    said
  end

  defp running(project, id) do
    handed_in(project, id)
    assert_receive {:fix, ^id, turns}, 15_000
    turns
  end

  defp queued(project, id) do
    said = handed_in(project, id)
    assert said =~ "queued", said
    assert id in Enum.map(Workflow.Run.queued_works(project.works), & &1["id"])
    refute File.exists?(Path.join(project.works, "#{id}.json"))
    refute_receive {:fix, ^id, _turns}, 300
  end

  test "the-queue: criteria 1 and 2, with five works running at a cap of five a sixth hand-in is queued, not refused, and starts on its own when one of the five finishes",
       %{tmp_dir: dir} do
    a = project(dir, "a", 5)
    [first | _] = for n <- 1..5, do: running(a, "w#{n}")

    # Criterion 1: queued, as it was handed in.
    queued(a, "w6")

    assert [%{"id" => "w6", "kind" => "issue", "text" => "Fault w6."}] =
             Workflow.Run.queued_works()

    # Criterion 2: w1 finishes (lands, and waits at ci holding no slot): w6 starts.
    send(first, :go)
    assert_receive {:fix, "w6", _turns}, 15_000
    assert Workflow.Run.queued_works() == []
  end

  test "the-queue: criterion 3, queued works from two projects on one machine start in hand-in order",
       %{tmp_dir: dir} do
    a = project(dir, "a", 1)
    b = project(dir, "b", 1)

    a1 = running(a, "a1")
    # b's is handed in first, then a's.
    queued(b, "b1")
    queued(a, "a2")

    # a's work finishes. a's loop does not take the slot for its own a2: b1 was
    # handed in first, and b's loop takes it.
    as(a)
    send(a1, :go)
    parked(a, "a1")
    refute_receive {:fix, "a2", _turns}, 300

    as(b)
    Workflow.Run.next_in_slot()
    assert_receive {:fix, "b1", b1}, 15_000
    refute_receive {:fix, "a2", _turns}, 300

    # b1 finishes: a2, the one left, starts at a's loop's next look for a slot.
    send(b1, :go)
    parked(b, "b1")
    as(a)
    Workflow.Run.next_in_slot()
    assert_receive {:fix, "a2", _turns}, 15_000
  end

  # Waits until the work has landed and parks at ci, holding no slot.
  defp parked(project, id, tries \\ 300) do
    file = Path.join(project.works, "#{id}.json")

    case File.read(file) do
      {:ok, json} when tries > 0 ->
        if Jason.decode!(json)["parked"] != true, do: retry(project, id, tries)

      _none when tries > 0 ->
        retry(project, id, tries)

      _none ->
        flunk("#{id} never parked")
    end
  end

  defp retry(project, id, tries) do
    Process.sleep(50)
    parked(project, id, tries - 1)
  end

  test "the-queue: criterion 4, after a project's queue is reordered the work now at the top starts at the next free slot",
       %{tmp_dir: dir} do
    a = project(dir, "a", 1)
    a1 = running(a, "a1")
    queued(a, "a2")
    queued(a, "a3")

    assert :ok = Workflow.Run.reorder(["a3", "a2"])
    assert ["a3", "a2"] = Enum.map(Workflow.Run.queued_works(), & &1["id"])

    send(a1, :go)
    assert_receive {:fix, "a3", _turns}, 15_000
    refute_receive {:fix, "a2", _turns}, 300
    assert ["a2"] = Enum.map(Workflow.Run.queued_works(), & &1["id"])
  end
end
