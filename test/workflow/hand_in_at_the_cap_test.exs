defmodule Workflow.HandInAtTheCapTest do
  # Not async: the manager and its run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  setup do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)
  end

  defp git!(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(out)
  end

  test "hand-in-at-the-cap-says-so: a hand-in made while the cap's worth of works are running answers promptly, queued at the cap of N, with its file in the works directory",
       %{tmp_dir: dir} do
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
      "agents" => %{"coder" => %{"provider" => "claude-code"}},
      "cap" => 2
    })

    test = self()

    # An agent handed a work says so, and stays at it: the work keeps running.
    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:agent, step.name, work["id"]})
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
    assert_received {:tools, tools}
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))
    issue = fn id -> %{"kind" => "issue", "id" => id, "text" => "Fault #{id}."} end

    # The cap's worth of works, each running with its agent at it.
    for id <- ["i1", "i2"] do
      assert {:ok, _said} = hand_in.execute.(issue.(id), %{})
      assert_receive {:agent, "fix", ^id}, 15_000
    end

    # One more, made as Alloy makes a tool call: one that overruns is killed. It
    # answers well under Alloy's 120 s tool timeout.
    began = System.monotonic_time(:millisecond)
    call = Task.async(fn -> hand_in.execute.(issue.("i3"), %{}) end)
    answered = Task.yield(call, 5_000) || Task.shutdown(call, :brutal_kill)
    assert System.monotonic_time(:millisecond) - began < 5_000

    # The tool result names the outcome: accepted and queued at the cap (the-queue).
    assert {:ok, {:ok, said}} = answered
    assert said =~ "queued"
    assert said =~ "at the cap of 2"

    # Queued: its file is in the works directory, waiting for a slot; it is not
    # in flight, has no copy, and no agent is at it.
    assert [%{"id" => "i3"}] = Workflow.Run.queued_works()
    refute File.exists?(Path.join(Workflow.Run.works_dir(), "i3.json"))
    refute File.dir?(Workflow.Checkout.root(repo, "i3"))
    refute_receive {:agent, _step, "i3"}, 200
  end
end
