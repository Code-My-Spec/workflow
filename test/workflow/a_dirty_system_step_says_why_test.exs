defmodule Workflow.ADirtySystemStepSaysWhyTest do
  # Not async: the command a checkout runs, the agent, the manager, and where
  # works in flight are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    test = self()

    was =
      for key <- [:cmd, :works_dir, :agents_run, :manager, :manager_run, :recipients],
          do: {key, Application.get_env(:workflow, key)}

    # Git is real; `just` is never run, and passes.
    Application.put_env(:workflow, :cmd, fn
      "just", _args, _opts -> {"", 0}
      command, args, opts -> System.cmd(command, args, opts)
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.delete_env(:workflow, :recipients)

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      send(test, {:manager_told, message})
      {:ok, %{text: "noted", messages: opts[:messages]}}
    end)

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    git(main, ~w(init -q -b main))
    git(main, ~w(config user.name t))
    git(main, ~w(config user.email t@example.com))
    commit(main, "flaky_test.exs", "flaky\n", "first")

    root = Path.join(dir, "f1")
    git(main, ["worktree", "add", "-q", "-b", "issue/f1", root])
    commit(root, "flaky_test.exs", "steady\n", "the fix")

    # A flake, handed in as the loop hands one in: an issue.
    work = %{"kind" => "issue", "id" => "f1", "root" => root, "text" => "A flaky test."}

    %{root: root, work: work, in_flight: Path.join([dir, "works", "f1.json"])}
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

  defp landed(file, tries \\ 500) do
    cond do
      not File.exists?(file) -> :ok
      tries == 0 -> flunk("#{file} still in flight")
      true -> Process.sleep(10) && landed(file, tries - 1)
    end
  end

  # The reviewer passes the fix, its own check run leaving untracked logs behind.
  defp reviewer(root, %{name: "review"}) do
    File.write!(Path.join(root, "certify-1.log"), "ran\n")
    File.write!(Path.join(root, "certify-2.log"), "ran\n")
    {%{"status" => "pass"}, nil}
  end

  test "a-dirty-system-step-says-why: criteria 1 and 3 - a flake whose tree has untracked files at promote goes back to its coder with git's status as its note, nothing deleted",
       %{root: root, work: work, in_flight: file} do
    test = self()
    work = Map.put(work, "agent", %{"provider" => "claude-code"})

    Application.put_env(:workflow, :agents_run, fn
      %{name: "review"} = step, _work ->
        reviewer(root, step)

      %{name: "fix"} = step, _work ->
        send(test, {:coder, self(), step.note})
        receive do: (:never -> {%{}, nil})
    end)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      assert_receive {:coder, turns, note}, 5_000
      status = git(root, ~w(status --short))
      assert status =~ "?? certify-1.log"
      assert note =~ "`git status --short` says"
      assert note =~ status
      assert Workflow.Run.stopped(work) == nil

      # Promote ignored nothing and nothing was deleted: the files are still there.
      assert File.exists?(Path.join(root, "certify-1.log"))
      assert File.exists?(Path.join(root, "certify-2.log"))

      Process.exit(turns, :kill)
      landed(file)
    end)
  end

  test "a-dirty-system-step-says-why: criterion 2 - a work with no agent to hand a dirty promote back to says, in its log line and to the manager, that the tree was dirty and what git's status is",
       %{root: root, work: work, in_flight: file} do
    # Only the reviewer can run: no coder to hand the dirty tree to.
    work = Map.put(work, "agents", %{"reviewer" => %{"provider" => "claude-code"}})
    Application.put_env(:workflow, :agents_run, fn step, _work -> reviewer(root, step) end)

    log =
      capture_log(fn ->
        assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
        landed(file)
        Workflow.Settled.idle()
      end)

    status = git(root, ~w(status --short))
    assert status =~ "?? certify-1.log"
    assert status =~ "?? certify-2.log"

    [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "[Workflow f1] promote"))
    assert line =~ "uncommitted changes"
    assert log =~ "`git status --short` says:\n\n#{status}"

    assert_received {:manager_told, told}
    assert told =~ "stopped at promote"
    assert told =~ "uncommitted changes"
    assert told =~ status

    assert %{} = Workflow.Run.stopped(work)
    assert File.exists?(Path.join(root, "certify-1.log"))
  end
end
