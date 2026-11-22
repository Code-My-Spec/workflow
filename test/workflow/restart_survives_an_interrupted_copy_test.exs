defmodule Workflow.RestartSurvivesAnInterruptedCopyTest do
  # Not async: the works directory is the whole application's.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias Workflow.Checkout

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    was = Application.get_env(:workflow, :works_dir)
    works = Path.join(dir, "works")
    Application.put_env(:workflow, :works_dir, works)

    on_exit(fn ->
      if was,
        do: Application.put_env(:workflow, :works_dir, was),
        else: Application.delete_env(:workflow, :works_dir)
    end)

    # A fake copy-setup: its first run is cut short (it waits until told to give up,
    # leaving no mark); every run after it marks `setup` and passes.
    marks = Path.join(dir, "marks")
    started = Path.join(dir, "started")
    abort = Path.join(dir, "abort")

    justfile = """
    copy-setup:
        if [ -e "#{started}" ]; then echo setup >> "#{marks}"; else touch "#{started}"; while [ ! -e "#{abort}" ]; do sleep 0.05; done; exit 1; fi

    copy-teardown:
    """

    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    File.write!(Path.join(main, "justfile"), justfile)

    for args <- [
          ~w(init -q -b main),
          ~w(config user.name t),
          ~w(config user.email t@example.com),
          ~w(add -A),
          ~w(commit -q -m first)
        ],
        do: git(main, args)

    work = %{"kind" => "issue", "id" => "i1", "repo" => main, "text" => "Fault: a fault."}

    %{
      main: main,
      work: work,
      works: works,
      marks: marks,
      started: started,
      abort: abort
    }
  end

  defp git(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    out
  end

  # Kept in flight, as the service had it when it went down.
  defp in_flight(works, work) do
    File.mkdir_p!(works)
    file = Path.join(works, "#{work["id"]}.json")
    File.write!(file, Jason.encode!(work))
    file
  end

  # Waits on the resumed run ending, not on a clock; one still in flight then holds its slot.
  defp landed(file) do
    Workflow.Settled.idle()
    refute File.exists?(file), "the work is still in flight, holding a slot: #{file}"
  end

  defp wait_for(file, tries \\ 200) do
    cond do
      File.exists?(file) -> :ok
      tries == 0 -> flunk("never made: #{file}")
      true -> Process.sleep(50) && wait_for(file, tries - 1)
    end
  end

  test "restart-survives-an-interrupted-copy: criteria 1 and 3 - a leftover issue/<id> branch with no worktree is made afresh on restart, copy-setup runs, the work reaches its first step and leaves flight",
       %{main: main, work: work, works: works, marks: marks, started: started} do
    # Cut short after `git worktree add -b` made the branch, before the worktree.
    git(main, ~w(branch issue/i1))
    File.write!(started, "")
    refute File.dir?(Checkout.root(main, "i1"))
    file = in_flight(works, work)

    log =
      capture_log(fn ->
        assert Workflow.Run.resume() == :ok
        landed(file)
      end)

    refute log =~ "MatchError"
    assert File.read!(marks) == "setup\n"
    assert File.dir?(Checkout.root(main, "i1"))
    assert %{name: "fix"} = Workflow.Run.step(work)
    assert File.read!(marks) == "setup\n"
  end

  test "restart-survives-an-interrupted-copy: criteria 2 and 3 - a leftover worktree whose copy-setup never finished is not reused as finished on restart: copy-setup runs again, the work reaches its first step and leaves flight",
       %{main: main, work: work, works: works, marks: marks, started: started, abort: abort} do
    # The service goes down mid copy-setup: the worktree is made, copy-setup never ends.
    {pid, ref} = spawn_monitor(fn -> Checkout.own(main, "issue", "i1", nil) end)
    wait_for(started)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    File.write!(abort, "")
    assert File.dir?(Checkout.root(main, "i1"))
    refute File.exists?(marks)
    file = in_flight(works, work)

    log =
      capture_log(fn ->
        assert Workflow.Run.resume() == :ok
        landed(file)
      end)

    refute log =~ "MatchError"
    assert File.read!(marks) == "setup\n"
    assert %{name: "fix"} = Workflow.Run.step(work)
    assert File.read!(marks) == "setup\n"
  end
end
