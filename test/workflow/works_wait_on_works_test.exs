defmodule Workflow.WorksWaitOnWorksTest do
  # Not async: the command a checkout runs, the agent, the manager, the machine,
  # the server line's name and where works in flight are kept, are app-wide.
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

  defp project(dir, cap) do
    repo = Path.join(dir, "repo")
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
    works = Path.join(dir, "works")
    Application.put_env(:workflow, :works_dir, works)
    Application.put_env(:workflow, :manager, manager)

    %{
      cap: cap,
      works: works,
      hand_in: Enum.find(tools, &(&1.name == "hand_in")).execute,
      stop: Enum.find(tools, &(&1.name == "stop")).execute
    }
  end

  defp handed_in(project, id, waits_on \\ nil) do
    issue = %{"kind" => "issue", "id" => id, "text" => "Fault #{id}."}
    issue = if waits_on, do: Map.put(issue, "after", waits_on), else: issue
    assert {:ok, said} = project.hand_in.(issue, %{})
    refute said =~ "Refused", said
    said
  end

  defp running(project, id) do
    handed_in(project, id)
    assert_receive {:fix, ^id, turns}, 15_000
    turns
  end

  defp queued_ids, do: Enum.map(Workflow.Run.queued_works(), & &1["id"])

  # Waits until the work has landed and parks at ci, or is done: no longer holding a slot.
  defp settled(project, id, tries \\ 300) do
    file = Path.join(project.works, "#{id}.json")

    held =
      case File.read(file) do
        {:ok, json} -> Jason.decode!(json)["parked"] != true
        _none -> false
      end

    cond do
      not held -> :ok
      tries > 0 -> Process.sleep(50) && settled(project, id, tries - 1)
      true -> flunk("#{id} never landed")
    end
  end

  test "works-wait-on-works: criteria 1 and 2, a work handed in after X holds no slot while X has not landed, and starts on its own once X lands",
       %{tmp_dir: dir} do
    p = project(dir, 3)
    x = running(p, "x")

    # Criterion 1: slots are free (one of three taken), yet it is held.
    said = handed_in(p, "y", ["x"])
    assert said =~ "queued", said
    assert said =~ "x", said
    refute_receive {:fix, "y", _turns}, 500
    assert queued_ids() == ["y"]
    refute File.exists?(Path.join(p.works, "y.json"))
    assert {1, 3} = Workflow.Machine.in_flight(p.cap)
    assert Workflow.Run.waits_on(hd(Workflow.Run.queued_works())) == ["x"]

    # A slot freeing for another reason does not start it.
    Workflow.Run.next_in_slot()
    refute_receive {:fix, "y", _turns}, 300

    # Criterion 2: x lands; y starts on its own.
    send(x, :go)
    assert_receive {:fix, "y", _turns}, 15_000
    assert queued_ids() == []
  end

  test "works-wait-on-works: a held work keeps its place, and the queue's next eligible work starts past it",
       %{tmp_dir: dir} do
    p = project(dir, 1)
    x = running(p, "x")
    handed_in(p, "y", ["x"])
    handed_in(p, "z")
    assert queued_ids() == ["y", "z"]

    # x lands: y, first in the queue and now eligible, takes the slot before z.
    send(x, :go)
    assert_receive {:fix, "y", _turns}, 15_000
    refute_receive {:fix, "z", _turns}, 300
    assert queued_ids() == ["z"]
  end

  test "works-wait-on-works: criterion 3, when X is stopped the work handed in after X stays held and is reported as waiting on a stopped work",
       %{tmp_dir: dir} do
    p = project(dir, 1)
    w = running(p, "w")
    handed_in(p, "x")
    handed_in(p, "y", ["x"])
    assert queued_ids() == ["x", "y"]

    # A line to the server, stubbed: this test takes its reports.
    Process.register(self(), Workflow.Server)
    assert {:ok, said} = p.stop.(%{"id" => "x", "kind" => "issue"}, %{})
    assert said =~ "stopped", said

    assert_receive {:report,
                    %{
                      "work" => "y",
                      "work_status" => "queued",
                      "waiting_on" => ["x"],
                      "note" => note
                    }},
                   5_000

    assert note =~ "waiting on a stopped work"
    assert note =~ "x"
    Process.unregister(Workflow.Server)

    # The slot frees: y is never started on its own.
    send(w, :go)
    settled(p, "w")
    Workflow.Run.next_in_slot()
    refute_receive {:fix, "y", _turns}, 500
    assert queued_ids() == ["y"]
  end
end
