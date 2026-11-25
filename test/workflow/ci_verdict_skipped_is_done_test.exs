defmodule Workflow.CiVerdictSkippedIsDoneTest do
  # Not async: the command a checkout runs, the agent, the manager, and where
  # works in flight are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias Workflow.Checkout

  @note "No CI runs for this project yet; certify was the gate."

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

    # A fake manager: what it is told comes to the test.
    Application.delete_env(:workflow, :recipients)

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      send(test, {:manager_told, message})
      {:ok, %{text: "noted", messages: opts[:messages]}}
    end)

    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    git(main, ~w(init -q -b main))
    git(main, ~w(config user.name t))
    git(main, ~w(config user.email t@example.com))
    commit(main, "fix.txt", "broken\n", "first")

    root = Path.join(dir, "i1")
    git(main, ["worktree", "add", "-q", "-b", "issue/i1", root])
    commit(root, "fix.txt", "fixed\n", "issue i1: the fix")

    work = %{
      "kind" => "issue",
      "id" => "i1",
      "root" => root,
      "repo" => main,
      "agent" => %{"provider" => "claude-code"}
    }

    %{main: main, root: root, work: work, in_flight: Path.join([dir, "works", "i1.json"])}
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit(dir, file, content, message) do
    File.write!(Path.join(dir, file), content)
    git(dir, ["add", file])
    git(dir, ["commit", "-q", "-m", message])
  end

  # Through certify, review (passed) and promote: landed, waiting at ci.
  defp land(work, file) do
    Application.put_env(:workflow, :agents_run, fn
      %{name: "review"}, _work -> {%{"status" => "pass"}, nil}
      step, _work -> flunk("no #{step.name} turn was expected")
    end)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      Workflow.Settled.idle()
    end)

    assert %{step: "ci", actor: :external, done: false} = Workflow.Run.look(work)
    assert File.exists?(file)
    flush()

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      flunk("no #{step.name} turn was expected")
    end)
  end

  defp flush do
    receive do
      _any -> flush()
    after
      0 -> :ok
    end
  end

  defp told do
    receive do
      {:manager_told, notice} -> if notice =~ "issue i1: done", do: notice, else: told()
    after
      0 -> flunk("the manager was not told the work is done")
    end
  end

  test "ci-verdict-skipped-is-done: criteria 1 and 2 - a landed work given a ci event with verdict skipped ends done and released, its final note holding the payload's note",
       %{work: work, in_flight: file} do
    land(work, file)

    capture_log(fn ->
      assert Workflow.Run.event("i1", "ci", %{"verdict" => "skipped", "note" => @note}) == :ok
      Workflow.Settled.idle()
    end)

    refute File.exists?(file), "the work done is still in flight"
    assert %{done: true, note: @note} = Workflow.Run.look(work)
    assert told() =~ @note
  end

  test "ci-verdict-skipped-is-done: criteria 1 and 2 - a landed work with a skipped ci event recorded ends done after a restart, its final note holding the payload's note",
       %{root: root, work: work, in_flight: file} do
    land(work, file)
    Checkout.record(root, "i1", "ci", %{"event" => "ci", "verdict" => "skipped", "note" => @note})

    capture_log(fn ->
      assert Workflow.Run.resume() == :ok
      Workflow.Settled.idle()
    end)

    refute File.exists?(file), "the work done is still in flight"
    assert %{done: true, note: @note} = Workflow.Run.look(work)
    assert told() =~ @note
  end

  test "ci-verdict-skipped-is-done: criterion 2 - with no note in the payload, the final note reads as a green one does",
       %{work: work, in_flight: file} do
    land(work, file)

    capture_log(fn ->
      assert Workflow.Run.event("i1", "ci", %{"verdict" => "skipped"}) == :ok
      Workflow.Settled.idle()
    end)

    refute File.exists?(file)
    assert %{done: true, note: nil} = Workflow.Run.look(work)
    refute told() =~ "ci:"
  end

  test "ci-verdict-skipped-is-done: criterion 3 - a ci event with an unknown verdict is handled as it is today",
       %{work: work, in_flight: file} do
    land(work, file)

    capture_log(fn ->
      assert Workflow.Run.event("i1", "ci", %{"verdict" => "purple"}) == :ok
      Workflow.Settled.idle()
    end)

    refute File.exists?(file)
    assert %{done: true, note: nil} = Workflow.Run.look(work)
  end
end
