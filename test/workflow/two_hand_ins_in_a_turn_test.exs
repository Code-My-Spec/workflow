defmodule Workflow.TwoHandInsInATurnTest do
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

  test "hand-in-at-the-cap-says-so: two hand-ins made in one manager turn below the cap both answer promptly, each with its works file written",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")
    # A copy-setup that outlasts the 5 s each hand-in is given here, as `mix
    # deps.get` outlasted the 120 s tool timeout live: one made inside the
    # hand-in cannot answer in time.
    File.write!(
      Path.join([repo, "proj", "justfile"]),
      "copy-setup:\n\tsleep 8\n\ncopy-teardown:\n"
    )

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
      "cap" => 3
    })

    test = self()

    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:agent, step.name, work["id"]})
      receive do: (:never -> {%{}, nil})
    end)

    # One manager turn that hands in two works, one after the other, each as
    # Alloy runs a tool call: in a task of its own, killed if it overruns.
    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      hand_in = Enum.find(opts[:tools], &(&1.name == "hand_in"))

      for id <- ["i1", "i2"] do
        began = System.monotonic_time(:millisecond)
        issue = %{"kind" => "issue", "id" => id, "text" => "Fault #{id}."}
        call = Task.async(fn -> hand_in.execute.(issue, %{}) end)
        answered = Task.yield(call, 5_000) || Task.shutdown(call, :brutal_kill)
        took = System.monotonic_time(:millisecond) - began
        works_file = File.exists?(Path.join(Workflow.Run.works_dir(), "#{id}.json"))
        send(test, {:handed_in, id, answered, took, works_file})
      end

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

    Task.start(fn -> Workflow.Manager.tell("hand in two") end)

    for id <- ["i1", "i2"] do
      assert_receive {:handed_in, ^id, answered, took, works_file}, 20_000
      assert {:ok, {:ok, said}} = answered, "#{id}'s hand-in did not answer in 5 s"
      assert said =~ "#{id}: on copy-setup (system), started."
      assert took < 5_000
      assert works_file, "#{id} left no works file"
    end

    # Both go on to their agents.
    assert_receive {:agent, "fix", "i1"}, 30_000
    assert_receive {:agent, "fix", "i2"}, 30_000
  end
end
