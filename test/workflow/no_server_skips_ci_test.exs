defmodule Workflow.NoServerSkipsCiTest do
  # Not async: the command a checkout runs, the agent, the manager, the server and
  # where works in flight are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  @note "no server, certify was the gate"

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
    Application.put_env(:workflow, :push, %{"remote" => "nowhere", "branch" => "main"})
    Application.delete_env(:workflow, :recipients)
    Application.delete_env(:workflow, :server)

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      send(test, {:manager_told, message})
      {:ok, %{text: "noted", messages: opts[:messages]}}
    end)

    # A fake agents run: the review passes, and no other turn is expected.
    Application.put_env(:workflow, :agents_run, fn
      %{name: "review"}, _work -> {%{"status" => "pass"}, nil}
      step, _work -> flunk("no #{step.name} turn was expected")
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

    # A stubbed server: its state dir holds no sign-in, so nothing is asked of it.
    server = %{"url" => "ws://x", "project_id" => "p1", "state_dir" => Path.join(dir, "state")}

    %{work: work, server: server, in_flight: Path.join([dir, "works", "i1.json"])}
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

  # Through certify, review (passed) and promote.
  defp land(work) do
    capture_log(fn ->
      Workflow.Run.start(work)
      Workflow.Settled.idle()
    end)
  end

  defp told do
    receive do
      {:manager_told, notice} -> if notice =~ "issue i1: done", do: notice, else: told()
    after
      0 -> flunk("the manager was not told the work is done")
    end
  end

  test "no-server-skips-ci: criterion 1 - with no server configured, a work that lands passes ci at once as skipped and is done",
       %{work: work, in_flight: file} do
    land(work)

    refute File.exists?(file), "the work done is still in flight"
    assert %{done: true, note: @note} = Workflow.Run.look(work)
    assert %{"ci" => %{"verdict" => "skipped", "note" => @note}} = Workflow.Run.look(work).found
    assert told() =~ @note
  end

  test "no-server-skips-ci: criterion 2 - with no server configured, a work already parked at ci when the loop starts finishes as skipped",
       %{work: work, server: server, in_flight: file} do
    # Parked at ci by a loop that had a server.
    Application.put_env(:workflow, :server, server)
    land(work)
    assert %{step: "ci", done: false} = Workflow.Run.look(work)
    assert %{"parked" => true} = file |> File.read!() |> Jason.decode!()

    # The loop starts again with no server.
    Application.delete_env(:workflow, :server)

    capture_log(fn ->
      assert Workflow.Run.resume() == :ok
      Workflow.Settled.idle()
    end)

    refute File.exists?(file), "the work done is still in flight"
    assert %{done: true, note: @note} = Workflow.Run.look(work)
    assert %{"ci" => %{"verdict" => "skipped"}} = Workflow.Run.look(work).found
  end

  # Parked at ci by a loop that had a server, its in-flight file then rewritten by `change`,
  # and the loop started again with no server.
  defp restarted_without_server(work, server, file, change) do
    Application.put_env(:workflow, :server, server)
    land(work)
    assert %{step: "ci", done: false} = Workflow.Run.look(work)

    file
    |> File.read!()
    |> Jason.decode!()
    |> change.()
    |> Jason.encode!()
    |> then(&File.write!(file, &1))

    Application.delete_env(:workflow, :server)

    # At once: no check runs again, and no agent is given a turn.
    test = self()

    Application.put_env(:workflow, :cmd, fn
      "just", args, _opts -> send(test, {:just, args}) && {"", 0}
      command, args, opts -> System.cmd(command, args, opts)
    end)

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:turn, step.name})
      {%{"status" => "pass"}, nil}
    end)

    capture_log(fn ->
      assert Workflow.Run.resume() == :ok
      Workflow.Settled.idle()
    end)

    refute_received {:just, _args}, "a check ran again"
    refute_received {:turn, _step}, "an agent was given a turn"
  end

  # Seen live: two works kept in flight with no repo of their own to ask whether
  # they landed were resumed past the landed path, and sat at ci.
  test "skip-applies-to-every-parked-ci-work: criterion 1 - with no server, a work parked at ci that resume does not find landed finishes as skipped at startup",
       %{work: work, server: server, in_flight: file} do
    restarted_without_server(work, server, file, &Map.delete(&1, "repo"))

    refute File.exists?(file), "the work done is still in flight"
    assert %{done: true, note: @note} = Workflow.Run.look(work)
    assert %{"ci" => %{"verdict" => "skipped"}} = Workflow.Run.look(work).found
  end

  # The paths a work is kept in flight at ci by: parked by the landed path, or kept
  # by a turn or a hand-in, with or without a repo to ask whether it landed.
  for {path, drop} <- [
        {"parked, with its repo", []},
        {"not parked, with its repo", ["parked"]},
        {"parked, with no repo", ["repo"]},
        {"not parked, with no repo", ["parked", "repo"]}
      ] do
    @drop drop
    test "skip-applies-to-every-parked-ci-work: criterion 2 - with no server, a work at ci kept #{path} finishes as skipped at startup",
         %{work: work, server: server, in_flight: file} do
      restarted_without_server(work, server, file, &Map.drop(&1, @drop))

      refute File.exists?(file), "the work done is still in flight"
      assert %{done: true, note: @note} = Workflow.Run.look(work)
      assert %{"ci" => %{"verdict" => "skipped"}} = Workflow.Run.look(work).found
    end
  end

  test "no-server-skips-ci: criterion 3 - with a server configured, a landed work still waits at ci for the server's event",
       %{work: work, server: server, in_flight: file} do
    Application.put_env(:workflow, :server, server)
    land(work)

    assert %{step: "ci", actor: :external, done: false} = look = Workflow.Run.look(work)
    refute Map.has_key?(look.found, "ci")
    assert %{"parked" => true} = file |> File.read!() |> Jason.decode!()
  end
end
