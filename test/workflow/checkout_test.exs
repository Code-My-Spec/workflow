defmodule Workflow.CheckoutTest do
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Checkout
  import Workflow.Settled

  # The loop's background work is waited on (`idle/0`): none is left from a test before.
  setup do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)
  end

  # A checkout at tree `tree`, in the git directory `dir`, with `just` exiting `status`.
  defp fake(dir, tree, status) do
    test = self()

    Application.put_env(:workflow, :cmd, fn command, args, opts ->
      case {command, args} do
        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} ->
          {dir <> "\n", 0}

        {"git", ["rev-parse", "HEAD^{tree}"]} ->
          {"#{tree}\n", 0}

        {"git", ["merge" | _]} ->
          {"", 0}

        {"just", [recipe, analysis_dir]} ->
          send(test, {:just, recipe, analysis_dir, opts[:cd]})
          {"output", status}
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)
  end

  defp analysis_dir(dir, tree), do: Path.join([dir, "workflow", "analysis", tree])

  # A repository with one commit holding `files`, by real git.
  defp repo_with(main, files) do
    git = fn args -> {_, 0} = System.cmd("git", args, cd: main, stderr_to_stdout: true) end
    File.mkdir_p!(main)
    for {path, content} <- files, do: File.write!(Path.join(main, path), content)
    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.name", "t"])
    git.(["config", "user.email", "t@example.com"])
    git.(["add", "-A"])
    git.(["commit", "-q", "--allow-empty", "-m", "first"])
    main
  end

  test "copy-lifecycle-recipes: a real project's copy-setup runs once in a new copy, its copy-teardown before the copy goes",
       %{tmp_dir: dir} do
    # Stand-in recipes, each leaving a mark beside the repository: nothing real is set up or dropped.
    marks = Path.join(dir, "marks")

    justfile = """
    copy-setup:
        echo setup >> "#{marks}"

    copy-teardown:
        echo teardown >> "#{marks}"
    """

    main = repo_with(Path.join(dir, "main"), [{"justfile", justfile}])

    assert Checkout.own(main, "issue", "i1", nil) == main <> "-i1"
    assert Checkout.own(main, "issue", "i1", nil) == main <> "-i1"
    assert File.read!(marks) == "setup\n"

    assert :ok = Checkout.disown(main, "issue", "i1")
    assert File.read!(marks) == "setup\nteardown\n"
    refute File.dir?(main <> "-i1")
  end

  test "copy-lifecycle-recipes: a real project with no copy-setup recipe says so, and leaves no copy",
       %{tmp_dir: dir} do
    main = repo_with(Path.join(dir, "main"), [{"justfile", "certify dir:\n    true\n"}])

    assert {:error, why} = Checkout.own(main, "issue", "i1", nil)
    assert why =~ "this project has no copy-setup recipe"
    refute File.dir?(main <> "-i1")

    {branches, 0} = System.cmd("git", ["branch", "--list", "issue/i1"], cd: main)
    assert branches == ""
  end

  test "copy-lifecycle-recipes: a real copy-teardown that fails still has the copy and its branch removed",
       %{tmp_dir: dir} do
    main =
      repo_with(Path.join(dir, "main"), [
        {"justfile", "copy-setup:\n\ncopy-teardown:\n    exit 3\n"}
      ])

    assert Checkout.own(main, "issue", "i1", nil) == main <> "-i1"
    assert :ok = Checkout.remove(main, "issue", "i1")
    refute File.dir?(main <> "-i1")

    {branches, 0} = System.cmd("git", ["branch", "--list", "issue/i1"], cd: main)
    assert branches == ""
  end

  # The run folders at `tree`, oldest first.
  defp run_dirs(dir, tree) do
    tree_dir = analysis_dir(dir, tree)

    case File.ls(tree_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(&1 =~ ~r/^\d+$/))
        |> Enum.sort_by(&String.to_integer/1)
        |> Enum.map(&Path.join(tree_dir, &1))

      _none ->
        []
    end
  end

  defp sarif(text) do
    Jason.encode!(%{
      "version" => "2.1.0",
      "runs" => [
        %{
          "tool" => %{"driver" => %{"name" => "compiler"}},
          "results" => [%{"level" => "error", "message" => %{"text" => text}}]
        }
      ]
    })
  end

  test "certify analyses the project with the recipe certify, in a run folder of its own",
       %{tmp_dir: dir} do
    fake(dir, "t1", 0)

    assert %{"status" => "passed", "dir" => run} =
             Checkout.certify("/root", %{main: "trunk"}, "proj")

    assert_received {:just, "certify", ^run, "/root/proj"}
    assert run_dirs(dir, "t1") == [run]
  end

  test "test analyses the project with the recipe run, in a run folder of its own",
       %{tmp_dir: dir} do
    fake(dir, "t1", 0)

    assert %{"status" => "passed", "dir" => run} = Checkout.test("/root", "proj")

    assert_received {:just, "run", ^run, "/root/proj"}
    assert run_dirs(dir, "t1") == [run]
  end

  test "just exiting non-zero with no SARIF error result fails the step with its output", %{
    tmp_dir: dir
  } do
    fake(dir, "t1", 1)

    assert %{"status" => "failed", "note" => "output"} = Checkout.test("/root", nil)
  end

  test "keep keeps the work beside its results, less agent and agents; a second keep replaces it",
       %{tmp_dir: dir} do
    Application.put_env(:workflow, :cmd, fn
      "git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], _opts ->
        {dir <> "\n", 0}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    work = %{
      "kind" => "story",
      "id" => "s1",
      "criteria" => ["a"],
      "agent" => %{"provider" => "anthropic", "key" => "secret"},
      "agents" => %{"reviewer" => %{"provider" => "anthropic", "key" => "secret"}}
    }

    Checkout.keep("/root", "s1", work)

    assert Checkout.kept("/root", "s1") == Map.drop(work, ["agent", "agents"])

    Checkout.keep("/root", "s1", %{"kind" => "story", "id" => "s1", "criteria" => ["b"]})
    assert Checkout.kept("/root", "s1")["criteria"] == ["b"]
  end

  # A checkout at tree t1 whose `just` writes `text` as an error result into the folder it is handed.
  defp failing(dir, text) do
    test = self()

    Application.put_env(:workflow, :cmd, fn command, args, opts ->
      case {command, args} do
        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} ->
          {dir <> "\n", 0}

        {"git", ["rev-parse", "HEAD^{tree}"]} ->
          {"t1\n", 0}

        {"git", ["merge" | _]} ->
          {"", 0}

        {"just", [recipe, run]} ->
          send(test, {:just, recipe, run, opts[:cd]})
          File.write!(Path.join(run, "compiler.sarif"), sarif(text.()))
          {"", 0}
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)
  end

  # Every `just` the stand-in was asked to run since last asked, as {recipe, run folder}, oldest first.
  defp justs do
    receive do
      {:just, recipe, run, _cd} -> [{recipe, run} | justs()]
    after
      0 -> []
    end
  end

  # A checkout at tree t1 whose `just` fails or passes by turns, as `outcomes` says
  # (`{:fail, text}` writes `text` as an error result; `:pass` writes nothing).
  defp scripted(dir, outcomes) do
    {:ok, left} = Agent.start_link(fn -> outcomes end)
    test = self()

    Application.put_env(:workflow, :cmd, fn command, args, opts ->
      case {command, args} do
        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} ->
          {dir <> "\n", 0}

        {"git", ["rev-parse", "HEAD^{tree}"]} ->
          {"t1\n", 0}

        {"git", ["merge" | _]} ->
          {"", 0}

        {"just", [recipe, run]} ->
          send(test, {:just, recipe, run, opts[:cd]})

          case Agent.get_and_update(left, fn [next | rest] -> {next, rest} end) do
            {:fail, text} ->
              File.write!(Path.join(run, "compiler.sarif"), sarif(text))
              {"", 1}

            :pass ->
              {"", 0}
          end
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)
  end

  # A manager with no agent: an inbox, where what it is told is kept.
  defp inbox(dir) do
    keys = [:manager, :works_dir, :recipients]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :manager, %{"repo" => "/nowhere/repo"})
    Application.delete_env(:workflow, :recipients)
  end

  # What the manager was told, once the loop's background telling has ended.
  defp told do
    idle()
    Workflow.Messages.unread("manager")
  end

  test "flake-rerun: criterion 1 - a recipe that fails twice at one tree fails the step with the second run's note, two run folders kept",
       %{tmp_dir: dir} do
    inbox(dir)

    for {step, recipe} <- [
          {fn -> Checkout.certify("/root", %{main: "trunk"}, "proj") end, "certify"},
          {fn -> Checkout.test("/root", "proj") end, "run"}
        ] do
      File.rm_rf!(analysis_dir(dir, "t1"))
      scripted(dir, [{:fail, "first failure"}, {:fail, "second failure"}])

      assert %{"status" => "failed", "note" => note, "dir" => second} = step.()
      assert note =~ "second failure"
      refute note =~ "first failure"
      assert [{^recipe, first}, {^recipe, ^second}] = justs()
      assert run_dirs(dir, "t1") == [first, second]
    end

    assert told() == []
  end

  test "flake-rerun: criterion 2 - a recipe that fails then passes at one tree passes the step, keeps both runs, and tells the manager once it was flaky",
       %{tmp_dir: dir} do
    inbox(dir)

    for {step, recipe} <- [
          {fn -> Checkout.test("/root", "proj") end, "run"},
          {fn -> Checkout.certify("/root", %{main: "trunk"}, "proj") end, "certify"}
        ] do
      File.rm_rf!(analysis_dir(dir, "t1"))
      scripted(dir, [{:fail, "flaky #{recipe} failure"}, :pass])

      assert %{"status" => "passed", "dir" => second} = step.()
      assert [{^recipe, first}, {^recipe, ^second}] = justs()
      assert run_dirs(dir, "t1") == [first, second]
      assert File.exists?(Path.join(first, "compiler.sarif"))

      assert [%{"text" => text}] = told()
      assert text =~ "flaky"
      assert text =~ "t1"
      assert text =~ "just #{recipe}"
      assert text =~ "flaky #{recipe} failure"

      # Told once: nothing more comes.
      idle()
      assert Workflow.Messages.unread("manager") == []
    end
  end

  test "flake-rerun: criterion 3 - a recipe that passes on its first run is not run again",
       %{tmp_dir: dir} do
    for {step, recipe} <- [
          {fn -> Checkout.test("/root", "proj") end, "run"},
          {fn -> Checkout.certify("/root", %{main: "trunk"}, "proj") end, "certify"}
        ] do
      File.rm_rf!(analysis_dir(dir, "t1"))
      scripted(dir, [:pass])

      assert %{"status" => "passed", "dir" => run} = step.()
      assert [{^recipe, ^run}] = justs()
      assert run_dirs(dir, "t1") == [run]
    end
  end

  test "flake-rerun: criterion 4 - a failed verdict read back from a run kept at the tree is never rerun",
       %{tmp_dir: dir} do
    scripted(dir, [])

    for recipe <- ["run", "certify"] do
      kept = Path.join(analysis_dir(dir, "t1"), if(recipe == "run", do: "100", else: "200"))
      File.mkdir_p!(kept)
      File.write!(Path.join(kept, "compiler.sarif"), sarif("kept #{recipe} failure"))

      Workflow.Sarif.merge_meta(kept, %{
        "recipe" => recipe,
        "at" => "x",
        "took_ms" => 1,
        "exit" => 1
      })
    end

    assert %{"status" => "failed", "note" => run_note} = Checkout.test("/root", "proj")

    assert %{"status" => "failed", "note" => certify_note} =
             Checkout.certify("/root", %{main: "trunk"}, "proj")

    assert run_note =~ "kept run failure"
    assert certify_note =~ "kept certify failure"
    assert justs() == []
    assert length(run_dirs(dir, "t1")) == 2
  end

  test "evidence-runs: criterion 1 - a run writes its SARIF files and one meta.json into analysis/<tree>/<unix time>/, the folder just is handed",
       %{tmp_dir: dir} do
    failing(dir, fn -> "boom" end)
    before = System.os_time(:second)

    assert %{"status" => "failed", "note" => note, "dir" => run} =
             Checkout.certify("/root", %{main: "trunk"}, "proj")

    assert note =~ "boom"
    assert_received {:just, "certify", ^run, "/root/proj"}
    assert Path.dirname(run) == analysis_dir(dir, "t1")
    assert String.to_integer(Path.basename(run)) >= before
    assert File.exists?(Path.join(run, "compiler.sarif"))

    assert %{"recipe" => "certify", "at" => at, "took_ms" => took_ms, "exit" => 0} =
             Workflow.Sarif.meta(run)

    assert is_binary(at)
    assert is_integer(took_ms)
    # No meta.json for the tree as a whole: each run keeps its own.
    refute File.exists?(Path.join(analysis_dir(dir, "t1"), "meta.json"))
  end

  test "evidence-runs: criterion 2 - two runs of a recipe at one tree leave two run folders, neither overwritten",
       %{tmp_dir: dir} do
    {:ok, count} = Agent.start_link(fn -> 0 end)
    failing(dir, fn -> "failure #{Agent.get_and_update(count, &{&1 + 1, &1 + 1})}" end)

    # Each failing analysis is run twice (flake-rerun): four run folders in all.
    assert %{"dir" => first} = Checkout.test("/root", nil)
    Checkout.afresh(dir, "i1")
    assert %{"dir" => second} = Checkout.test("/root", nil)

    assert first != second
    assert [_, ^first, _, ^second] = run_dirs(dir, "t1")
    assert Path.join(first, "compiler.sarif") |> File.read!() =~ "failure 2"
    assert Path.join(second, "compiler.sarif") |> File.read!() =~ "failure 4"
    assert %{"recipe" => "run"} = Workflow.Sarif.meta(first)
    assert %{"recipe" => "run"} = Workflow.Sarif.meta(second)
  end

  test "evidence-runs: criterion 3 - the verdict is read from the recipe's latest run folder",
       %{tmp_dir: dir} do
    Application.put_env(:workflow, :cmd, fn
      "git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], _opts ->
        {dir <> "\n", 0}

      "git", ["rev-parse", "HEAD^{tree}"], _opts ->
        {"t1\n", 0}

      "just", _args, _opts ->
        flunk("just ran for a recipe with a run at this tree")
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    run = fn at, recipe, exit, text ->
      folder = Path.join(analysis_dir(dir, "t1"), Integer.to_string(at))
      File.mkdir_p!(folder)
      if text, do: File.write!(Path.join(folder, "compiler.sarif"), sarif(text))

      Workflow.Sarif.merge_meta(folder, %{
        "recipe" => recipe,
        "at" => "x",
        "took_ms" => 1,
        "exit" => exit
      })

      folder
    end

    run.(100, "certify", 1, "old failure")
    latest = run.(200, "certify", 0, nil)
    # A later run of another recipe is not certify's.
    run.(300, "run", 1, "run's failure")

    assert Checkout.analyse("/root", "proj", "certify") == %{
             "status" => "passed",
             "dir" => latest
           }

    failed = run.(400, "certify", 1, "new failure")

    assert %{"status" => "failed", "note" => note, "dir" => ^failed} =
             Checkout.analyse("/root", "proj", "certify")

    assert note =~ "new failure"
    refute note =~ "old failure"
  end

  test "evidence-runs: criterion 4 - a recipe already run at a tree is not run again: its latest run is read back",
       %{tmp_dir: dir} do
    failing(dir, fn -> "already failing" end)

    assert %{"status" => "failed", "dir" => run} = Checkout.analyse("/root", "proj", "certify")
    # Failed twice (flake-rerun): the second run is the step's.
    assert [{"certify", first}, {"certify", ^run}] = justs()

    assert %{"status" => "failed", "note" => note, "dir" => ^run} =
             Checkout.analyse("/root", "proj", "certify")

    assert note =~ "already failing"
    refute_received {:just, _recipe, _run, _cd}
    assert run_dirs(dir, "t1") == [first, run]
  end

  test "a recipe that failed with no error result is still failed when read again", %{
    tmp_dir: dir
  } do
    Application.put_env(:workflow, :cmd, fn
      "git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], _opts ->
        {dir <> "\n", 0}

      "git", ["rev-parse", "HEAD^{tree}"], _opts ->
        {"t1\n", 0}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    Workflow.Sarif.merge_meta(Path.join(analysis_dir(dir, "t1"), "100"), %{
      "recipe" => "certify",
      "at" => "x",
      "took_ms" => 1,
      "exit" => 1
    })

    assert %{"status" => "failed", "note" => note} = Checkout.analyse("/root", nil, "certify")
    assert note =~ "exit 1"
  end

  test "evidence-runs: criterion 5 - run afresh, a recipe makes a new run folder and runs again, the old evidence kept",
       %{tmp_dir: dir} do
    failing(dir, fn -> "boom" end)

    assert %{"dir" => old_certify} = Checkout.analyse("/root", nil, "certify")
    assert %{"dir" => old_run} = Checkout.analyse("/root", nil, "run")
    # Each fails twice (flake-rerun), so each is run twice.
    assert [{"certify", c1}, {"certify", ^old_certify}, {"run", r1}, {"run", ^old_run}] = justs()

    Checkout.afresh(dir, "i1")

    assert %{"dir" => new_certify} = Checkout.analyse("/root", nil, "certify")
    assert %{"dir" => new_run} = Checkout.analyse("/root", nil, "run")
    assert [{"certify", c2}, {"certify", ^new_certify}, {"run", r2}, {"run", ^new_run}] = justs()

    assert run_dirs(dir, "t1") ==
             [c1, old_certify, r1, old_run, c2, new_certify, r2, new_run]

    assert File.exists?(Path.join(old_certify, "compiler.sarif"))
    assert %{"recipe" => "certify", "exit" => 0} = Workflow.Sarif.meta(old_certify)

    # The new runs are read back after that, not run a third time.
    assert %{"dir" => ^new_certify} = Checkout.analyse("/root", nil, "certify")
    refute_received {:just, _recipe, _run, _cd}
  end

  test "push-to-dev: criterion 1", %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
      String.trim(out)
    end

    remote = Path.join(dir, "remote.git")
    main = Path.join(dir, "main")
    work = main <> "-w1"
    File.mkdir_p!(main)

    git.(dir, ["init", "--bare", remote])
    git.(main, ["init", "-b", "main"])
    git.(main, ["config", "user.name", "t"])
    git.(main, ["config", "user.email", "t@example.com"])
    git.(main, ["remote", "add", "origin", remote])
    git.(main, ["commit", "--allow-empty", "-m", "first"])
    git.(main, ["worktree", "add", "-b", "story/w1", work])
    git.(work, ["commit", "--allow-empty", "-m", "work"])

    assert %{"status" => "promoted"} = Checkout.promote(work, %{main_copy: main})
    assert git.(remote, ["rev-parse", "dev"]) == git.(main, ["rev-parse", "HEAD"])
  end

  test "push-to-dev: criterion 2", %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
      String.trim(out)
    end

    main = Path.join(dir, "main")
    work = main <> "-w1"
    File.mkdir_p!(main)

    git.(main, ["init", "-b", "main"])
    git.(main, ["config", "user.name", "t"])
    git.(main, ["config", "user.email", "t@example.com"])
    git.(main, ["commit", "--allow-empty", "-m", "first"])
    git.(main, ["worktree", "add", "-b", "story/w1", work])
    git.(work, ["commit", "--allow-empty", "-m", "work"])
    landed = git.(work, ["rev-parse", "HEAD"])

    assert git.(main, ["remote"]) == ""
    assert %{"status" => "promoted"} = Checkout.promote(work, %{main_copy: main})
    assert git.(main, ["merge-base", "--is-ancestor", landed, "HEAD"]) == ""
    assert git.(main, ["remote"]) == ""
  end

  test "push-to-dev: criterion 3", %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
      String.trim(out)
    end

    remote = Path.join(dir, "remote.git")
    main = Path.join(dir, "main")
    File.mkdir_p!(main)

    git.(dir, ["init", "--bare", remote])
    git.(main, ["init", "-b", "main"])
    git.(main, ["config", "user.name", "t"])
    git.(main, ["config", "user.email", "t@example.com"])
    git.(main, ["remote", "add", "origin", remote])
    git.(main, ["commit", "--allow-empty", "-m", "first"])

    hook = Path.join([remote, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho 'no pushing today' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)

    land = fn id ->
      work = main <> "-" <> id
      git.(main, ["worktree", "add", "-b", "story/" <> id, work])
      git.(work, ["commit", "--allow-empty", "-m", id])
      {work, Checkout.promote(work, %{main_copy: main}), git.(work, ["rev-parse", "HEAD"])}
    end

    {_work, refused, first} = land.("w1")

    assert %{"status" => "promoted", "note" => note} = refused
    assert note =~ "no pushing today"
    assert git.(main, ["merge-base", "--is-ancestor", first, "HEAD"]) == ""

    File.rm!(hook)
    {_work, _result, second} = land.("w2")

    assert git.(remote, ["rev-parse", "dev"]) == git.(main, ["rev-parse", "HEAD"])
    assert git.(remote, ["merge-base", "--is-ancestor", first, "dev"]) == ""
    assert git.(remote, ["merge-base", "--is-ancestor", second, "dev"]) == ""
  end

  test "push-to-dev: the remote and branch come from the push setting", %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
      String.trim(out)
    end

    remote = Path.join(dir, "remote.git")
    main = Path.join(dir, "main")
    work = main <> "-w1"
    File.mkdir_p!(main)

    git.(dir, ["init", "--bare", remote])
    git.(main, ["init", "-b", "main"])
    git.(main, ["config", "user.name", "t"])
    git.(main, ["config", "user.email", "t@example.com"])
    git.(main, ["remote", "add", "upstream", remote])
    git.(main, ["commit", "--allow-empty", "-m", "first"])
    git.(main, ["worktree", "add", "-b", "story/w1", work])
    git.(work, ["commit", "--allow-empty", "-m", "work"])

    Application.put_env(:workflow, :push, %{"remote" => "upstream", "branch" => "staging"})
    on_exit(fn -> Application.delete_env(:workflow, :push) end)

    assert %{"status" => "promoted"} = promoted = Checkout.promote(work, %{main_copy: main})
    refute Map.has_key?(promoted, "note")
    assert git.(remote, ["rev-parse", "staging"]) == git.(main, ["rev-parse", "HEAD"])
    assert git.(remote, ["branch", "--list", "dev"]) == ""
  end

  test "build-cop: criterion 1 - a refused push after a landing tells the manager, with the remote's output",
       %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
      String.trim(out)
    end

    keys = [:manager, :works_dir, :recipients]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    # A manager with no agent is an inbox: what it is told is kept there.
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :manager, %{"repo" => "/nowhere/repo"})
    Application.delete_env(:workflow, :recipients)

    remote = Path.join(dir, "remote.git")
    main = Path.join(dir, "main")
    work = main <> "-w1"
    File.mkdir_p!(main)

    git.(dir, ["init", "--bare", remote])
    git.(main, ["init", "-b", "main"])
    git.(main, ["config", "user.name", "t"])
    git.(main, ["config", "user.email", "t@example.com"])
    git.(main, ["remote", "add", "origin", remote])
    git.(main, ["commit", "--allow-empty", "-m", "first"])
    git.(main, ["worktree", "add", "-b", "story/w1", work])
    git.(work, ["commit", "--allow-empty", "-m", "work"])

    hook = Path.join([remote, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho 'ci: red at abc; push refused' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)

    assert %{"status" => "promoted"} = Checkout.promote(work, %{main_copy: main})

    told = told()

    assert [%{"text" => text}] = told
    assert text =~ "ci: red at abc; push refused"
  end

  test "loop-failures: the push-failure message ends by telling the manager to hand in an issue now, without asking",
       %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
      String.trim(out)
    end

    keys = [:manager, :works_dir, :recipients]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :manager, %{"repo" => "/nowhere/repo"})
    Application.delete_env(:workflow, :recipients)

    remote = Path.join(dir, "remote.git")
    main = Path.join(dir, "main")
    work = main <> "-w1"
    File.mkdir_p!(main)

    git.(dir, ["init", "--bare", remote])
    git.(main, ["init", "-b", "main"])
    git.(main, ["config", "user.name", "t"])
    git.(main, ["config", "user.email", "t@example.com"])
    git.(main, ["remote", "add", "origin", remote])
    git.(main, ["commit", "--allow-empty", "-m", "first"])
    git.(main, ["worktree", "add", "-b", "story/w1", work])
    git.(work, ["commit", "--allow-empty", "-m", "work"])

    hook = Path.join([remote, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho 'mix format --check-formatted failed' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)

    assert %{"status" => "promoted", "note" => note} = Checkout.promote(work, %{main_copy: main})

    told = told()

    assert [%{"text" => text}] = told
    assert text == note
    assert text =~ "mix format --check-formatted failed"
    assert String.ends_with?(text, "Hand in an issue with this failure now; do not ask first.")
  end

  test "build-cop: criterion 2 - a refused push still counts the landing: the work is done and the main copy keeps the merge",
       %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
      String.trim(out)
    end

    remote = Path.join(dir, "remote.git")
    main = Path.join(dir, "main")
    work = main <> "-w1"
    File.mkdir_p!(main)

    git.(dir, ["init", "--bare", remote])
    git.(main, ["init", "-b", "main"])
    git.(main, ["config", "user.name", "t"])
    git.(main, ["config", "user.email", "t@example.com"])
    git.(main, ["remote", "add", "origin", remote])
    git.(main, ["commit", "--allow-empty", "-m", "first"])
    git.(main, ["worktree", "add", "-b", "story/w1", work])
    git.(work, ["commit", "--allow-empty", "-m", "work"])
    landed = git.(work, ["rev-parse", "HEAD"])

    hook = Path.join([remote, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho 'ci: red at abc; push refused' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)

    result = Checkout.promote(work, %{main_copy: main})

    assert %{"status" => "promoted"} = result
    assert git.(main, ["merge-base", "--is-ancestor", landed, "HEAD"]) == ""
    assert git.(main, ["status", "--porcelain"]) == ""

    snapshot = %{head: "h", main: "main", results: %{"h" => %{"promote" => result}}}
    assert Workflow.Issue.status(%{name: "promote"}, snapshot) == :done
  end

  test "build-cop: criterion 3 - a remote that cannot be reached tells the manager once with git's output, and nothing loops",
       %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
      String.trim(out)
    end

    keys = [:manager, :works_dir, :recipients]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    # A manager with no agent is an inbox: what it is told is kept there.
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :manager, %{"repo" => "/nowhere/repo"})
    Application.delete_env(:workflow, :recipients)

    unreachable = Path.join(dir, "no-such-remote.git")
    main = Path.join(dir, "main")
    work = main <> "-w1"
    File.mkdir_p!(main)

    git.(main, ["init", "-b", "main"])
    git.(main, ["config", "user.name", "t"])
    git.(main, ["config", "user.email", "t@example.com"])
    git.(main, ["remote", "add", "origin", unreachable])
    git.(main, ["commit", "--allow-empty", "-m", "first"])
    git.(main, ["worktree", "add", "-b", "story/w1", work])
    git.(work, ["commit", "--allow-empty", "-m", "work"])

    assert %{"status" => "promoted"} = Checkout.promote(work, %{main_copy: main})

    told = told()

    assert [%{"text" => text}] = told
    assert text =~ "does not appear to be a git repository"

    # Nothing retries on a timer: no second message arrives.
    idle()
    assert Workflow.Messages.unread("manager") == []
  end

  test "build-cop: criterion 4 - after a refused push the next landing's one push carries both commits, and nothing is pushed on a timer",
       %{tmp_dir: dir} do
    git = fn cwd, args ->
      {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
      String.trim(out)
    end

    remote = Path.join(dir, "remote.git")
    main = Path.join(dir, "main")
    File.mkdir_p!(main)

    git.(dir, ["init", "--bare", remote])
    git.(main, ["init", "-b", "main"])
    git.(main, ["config", "user.name", "t"])
    git.(main, ["config", "user.email", "t@example.com"])
    git.(main, ["remote", "add", "origin", remote])
    git.(main, ["commit", "--allow-empty", "-m", "first"])

    hook = Path.join([remote, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho 'ci: red at abc; push refused' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)

    land = fn id ->
      work = main <> "-" <> id
      git.(main, ["worktree", "add", "-b", "story/" <> id, work])
      git.(work, ["commit", "--allow-empty", "-m", id])
      Checkout.promote(work, %{main_copy: main})
      git.(work, ["rev-parse", "HEAD"])
    end

    first = land.("w1")

    # Nothing pushes again by itself.
    idle()
    assert git.(remote, ["branch", "--list", "dev"]) == ""

    File.rm!(hook)
    fix = land.("w2")

    assert git.(remote, ["rev-parse", "dev"]) == git.(main, ["rev-parse", "HEAD"])
    assert git.(remote, ["merge-base", "--is-ancestor", first, "dev"]) == ""
    assert git.(remote, ["merge-base", "--is-ancestor", fix, "dev"]) == ""
  end

  test "agents-commit-no-ignored-files: ignored_changes names changed tracked paths only when .gitignore names them all",
       %{tmp_dir: dir} do
    git = fn args -> {_, 0} = System.cmd("git", args, cd: dir) end
    git.(~w(init -q))
    File.mkdir_p!(Path.join(dir, "tmp"))
    File.write!(Path.join(dir, ".gitignore"), "tmp/\n")
    File.write!(Path.join(dir, "tmp/scratch.txt"), "one")
    File.write!(Path.join(dir, "a.ex"), "one")
    git.(~w(add .gitignore a.ex))
    git.(~w(add -f tmp/scratch.txt))
    git.(~w(-c user.name=t -c user.email=t@t commit -q -m first))

    assert Checkout.ignored_changes(dir) == []

    File.write!(Path.join(dir, "tmp/scratch.txt"), "two")
    assert Checkout.ignored_changes(dir) == ["tmp/scratch.txt"]

    File.write!(Path.join(dir, "a.ex"), "two")
    assert Checkout.ignored_changes(dir) == []
  end
end
