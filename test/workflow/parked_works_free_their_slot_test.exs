defmodule Workflow.ParkedWorksFreeTheirSlotTest do
  # Not async: the command a checkout runs, the agent, the manager, and where
  # works in flight are kept, are app-wide.
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Checkout

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    test = self()

    was =
      for key <- [
            :cmd,
            :works_dir,
            :agents_run,
            :push,
            :manager,
            :manager_run,
            :recipients,
            :server
          ],
          do: {key, Application.get_env(:workflow, key)}

    # A server is configured, so a landed work waits at ci for its event; its
    # state dir holds no sign-in, so nothing is asked of it.
    Application.put_env(:workflow, :server, %{
      "url" => "ws://x",
      "project_id" => "p1",
      "state_dir" => Path.join(dir, "state")
    })

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    # Git is real; `just` is never run, and passes.
    Application.put_env(:workflow, :cmd, fn
      "just", _args, _opts -> {"", 0}
      command, args, opts -> System.cmd(command, args, opts)
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    # No such remote: promote merges into the main copy and pushes nothing.
    Application.put_env(:workflow, :push, %{"remote" => "nowhere", "branch" => "main"})
    Application.delete_env(:workflow, :recipients)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      {:ok, %{text: "noted", messages: opts[:messages]}}
    end)

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

    # One slot.
    manager = %{
      "agent" => agent,
      "repo" => repo,
      "agents" => %{"coder" => agent, "reviewer" => agent},
      "cap" => 1
    }

    Application.put_env(:workflow, :manager, manager)

    # A coder says it is at work. On a `person` work it commits nothing, so it is
    # sent back until the work waits on its owner; on a `held` work it stays at it
    # until told to go. A reviewer passes.
    Application.put_env(:workflow, :agents_run, fn
      %{name: "review"}, _work ->
        {%{"status" => "pass"}, nil}

      %{name: "fix"}, %{"id" => id, "root" => root} ->
        send(test, {:fix, id, self()})
        if String.starts_with?(id, "held"), do: receive(do: (:go -> :ok))

        unless String.starts_with?(id, "person") do
          file = "#{id}-#{System.unique_integer([:positive])}.txt"
          File.write!(Path.join(root, file), "fixed\n")
          git(root, ["add", file])
          git(root, ["commit", "-q", "-m", "#{id}: a fix"])
        end

        {%{}, nil}
    end)

    tool = Enum.find(Workflow.Manager.tools(manager), &(&1.name == "hand_in"))

    hand_in = fn id ->
      {:ok, said} = tool.execute.(%{"kind" => "issue", "id" => id, "text" => "Fault #{id}."}, %{})
      said
    end

    %{repo: repo, hand_in: hand_in}
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp look(repo, id),
    do: Workflow.Run.look(%{"kind" => "issue", "id" => id, "root" => Checkout.root(repo, id)})

  # Handed in, run through fix, certify, review and promote: landed, waiting at ci.
  defp at_ci(repo, hand_in, id) do
    refute hand_in.(id) =~ "Refused"
    Workflow.Settled.idle()
    assert %{step: "ci", actor: :external, done: false} = look(repo, id)
    flush()
  end

  defp flush do
    receive do
      _any -> flush()
    after
      0 -> :ok
    end
  end

  test "parked-works-free-their-slot: criterion 1 - with the cap full and one work waiting on a person, a newly handed-in work still starts",
       %{repo: repo, hand_in: hand_in} do
    refute hand_in.("person1") =~ "Refused"
    Workflow.Settled.idle()

    assert Workflow.Run.stopped(%{"id" => "person1", "repo" => repo})["reason"] =~
             "waiting on its owner"

    refute hand_in.("held2") =~ "Refused"
    assert_receive {:fix, "held2", _turns}, 15_000
  end

  test "parked-works-free-their-slot: criterion 2 - a work waiting at the ci step holds no slot: another work starts in its place",
       %{repo: repo, hand_in: hand_in} do
    at_ci(repo, hand_in, "ci1")

    said = hand_in.("held2")
    refute said =~ "Refused", said
    assert_receive {:fix, "held2", _turns}, 15_000
  end

  test "parked-works-free-their-slot: criterion 3 - a parked work's answer with a slot free resumes it at once, at the step it was parked on",
       %{repo: repo, hand_in: hand_in} do
    at_ci(repo, hand_in, "ci1")

    assert Workflow.Run.event("ci1", "ci", %{"verdict" => "red", "failing" => ["t"]}) == :ok
    # The red verdict at ci, the step it was parked on, sends it back to its coder.
    assert_receive {:fix, "ci1", _turns}, 15_000
    Workflow.Settled.idle()
  end

  test "parked-works-free-their-slot: criterion 3 - a parked work's answer with no slot free resumes it as soon as one frees, interrupting nothing",
       %{repo: repo, hand_in: hand_in} do
    at_ci(repo, hand_in, "ci1")

    # The one slot is taken by a work whose coder is at it.
    refute hand_in.("held2") =~ "Refused"
    assert_receive {:fix, "held2", turns}, 15_000

    assert Workflow.Run.event("ci1", "ci", %{"verdict" => "red", "failing" => ["t"]}) == :ok
    refute_receive {:fix, "ci1", _turns}, 500
    assert Process.alive?(turns), "the running work was interrupted"

    # The running work goes on, lands and parks at ci: its slot frees, and the
    # waiting work resumes into it.
    send(turns, :go)
    assert_receive {:fix, "ci1", _turns}, 15_000
    Workflow.Settled.idle()
    assert %{step: "ci"} = look(repo, "held2")
  end
end
