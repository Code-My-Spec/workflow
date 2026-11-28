defmodule Workflow.LoopPrunesItsLeftoversTest do
  # Not async: the manager, its run and the works directory are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Checkout

  setup do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  # A repository by real git, with copy-setup and copy-teardown stand-ins that do nothing.
  defp repo(dir) do
    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    File.write!(Path.join(main, "justfile"), "copy-setup:\n\ncopy-teardown:\n")
    git(main, ["init", "-q", "-b", "main"])
    git(main, ["config", "user.name", "t"])
    git(main, ["config", "user.email", "t@example.com"])
    git(main, ["add", "-A"])
    git(main, ["commit", "-q", "-m", "first"])
    main
  end

  # A work's checkout at a tree of its own, a check recorded there with a run
  # folder and a log, and a conversation file: what the loop leaves for a work.
  defp work(main, workflow, id) do
    root = Checkout.own(main, "issue", id, nil)
    File.write!(Path.join(root, id), id)
    git(root, ["add", "-A"])
    git(root, ["commit", "-q", "-m", "issue #{id}: a commit"])
    tree = git(root, ~w(rev-parse HEAD^{tree}))
    Checkout.record(root, id, "run", %{"status" => "passed"})
    run = Path.join([workflow, "analysis", tree, "1700000000"])
    File.mkdir_p!(run)
    File.write!(Path.join(run, "meta.json"), "{}")
    File.write!(Path.join([workflow, "analysis", tree, "log"]), "a line\n")
    conversation = Path.join([workflow, "conversations", "#{id}.jsonl"])
    File.mkdir_p!(Path.dirname(conversation))
    File.write!(conversation, "{}\n")
    %{run: run, log: Path.join([workflow, "analysis", tree, "log"]), conversation: conversation}
  end

  test "loop-prunes-its-leftovers: criterion 1 - a work landed or stopped leaves no run folder or conversation of its own; a running work's are kept",
       %{tmp_dir: dir} do
    main = repo(dir)

    workflow =
      Path.join(git(main, ~w(rev-parse --path-format=absolute --git-common-dir)), "workflow")

    landed = work(main, workflow, "landed")
    stopped = work(main, workflow, "stopped")
    running = work(main, workflow, "running")

    # Done: its checkout is disowned. Stopped for good: removed.
    assert :ok = Checkout.disown(main, "issue", "landed")
    assert :ok = Checkout.remove(main, "issue", "stopped")

    for gone <- [landed, stopped] do
      refute File.exists?(gone.run)
      refute File.exists?(gone.conversation)
      # The log its landing or stop was said in is kept.
      assert File.exists?(gone.log)
    end

    assert File.exists?(running.run)
    assert File.exists?(running.conversation)
    assert File.exists?(running.log)
  end
end
