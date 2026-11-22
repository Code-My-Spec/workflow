defmodule Workflow.RunTest do
  # Not async: the command a checkout runs is swapped for the whole application.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  # A work that ends tells the manager from a task of its own, which `settled/0`
  # cannot see: the work's turns run under spawn_monitor, which drops `$callers`.
  # Left running, that telling reaches the one manager after the test, with the
  # next test's manager_run (its notice taken for that test's), or with none, the
  # real manager, holding every later telling for seconds. So none is left at the
  # start or end of a test.
  setup do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)
  end

  # A checkout with `commits` of its own at tree "t<commits>", its checks exiting
  # `checks`, merging main cleanly, and every command it was asked sent to the test.
  defp checkout(dir, commits, checks, opts \\ []) do
    test = self()

    # Checkouts the loop cuts land beside tmp_dir, outside what ExUnit cleans: a stale one is reused, not cut.
    Enum.each(Path.wildcard(dir <> "-*"), &File.rm_rf!/1)

    Application.put_env(:workflow, :cmd, fn command, args, call_opts ->
      send(test, {command, args})
      send(test, {:cwd, command, args, call_opts[:cd]})

      case {command, args} do
        # A ci checkout is cut detached at the landed commit, its path before the commit.
        {"git", ["worktree", "add", "--detach", path, _commit]} ->
          File.mkdir_p!(path)
          {"", 0}

        {"git", ["worktree", "add", "-b", _branch, path | _at]} ->
          File.mkdir_p!(path)
          {"", 0}

        {"git", ["worktree", "remove" | _]} ->
          {"", 0}

        {"git", ["branch", "-D" | _]} ->
          {"", 0}

        {"git", ["rev-parse", "HEAD^{tree}"]} ->
          {"t#{commits}\n", 0}

        {"git", ["worktree" | _]} ->
          {"worktree /main copy\nHEAD abc\n", 0}

        {"git", ["rev-parse", "--abbrev-ref", "HEAD"]} ->
          {"trunk\n", 0}

        {"git", ["rev-list" | _]} ->
          {"#{commits}\n", 0}

        {"git", ["status" | _]} ->
          {"", 0}

        # This test's checkouts share `dir`'s git directory. A run another test
        # left going calls this same stand-in from that test's directory: it is
        # answered its own, so it never reads or rewrites this test's results
        # for the same work id.
        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} ->
          cd = call_opts[:cd] || dir

          other_test? =
            String.starts_with?(cd, Path.dirname(dir) <> "/") and
              not String.starts_with?(cd, dir)

          {if(other_test?, do: cd, else: dir) <> "\n", 0}

        {"git", ["rev-parse", "HEAD"]} ->
          {"c#{commits}\n", 0}

        {"git", ["merge" | _]} ->
          {"", 0}

        {"git", ["remote" | _]} ->
          {"", 0}

        {"git", ["push" | _]} ->
          {"", 0}

        {"git", ["diff", "--shortstat" | _]} ->
          {" 2 files changed, 3 insertions(+), 1 deletion(-)\n", 0}

        # A story or journey handed in is committed as stories/<id>.yml.
        {"git", ["add" | _]} ->
          {"", 0}

        {"git", ["commit" | _]} ->
          {"", 0}

        {"just", _} ->
          {"3 tests, 1 failure", checks}

        {"mix", _args} ->
          {"3 tests, 1 failure", checks}
      end
    end)

    on_exit(fn ->
      # A deploy still running in the background would land in the next test's settings.
      deploying = fn deploying ->
        if Enum.any?(:global.registered_names(), &match?({Workflow.Run, :deploy, _}, &1)) do
          Process.sleep(10)
          deploying.(deploying)
        end
      end

      deploying.(deploying)
      Application.delete_env(:workflow, :cmd)
    end)

    case opts[:repo] do
      nil -> %{"kind" => "issue", "id" => "i1", "root" => dir, "project" => "workflow"}
      repo -> %{"kind" => "issue", "id" => "i1", "repo" => repo, "project" => "workflow"}
    end
  end

  test "nothing committed is the coder's, and nothing is checked", %{tmp_dir: dir} do
    assert %{name: "fix", actor: :coder} = Workflow.Run.step(checkout(dir, 0, 0))
    refute_received {"mix", _args}
  end

  test "a fix is merged with main, checked in its project, and left for review", %{tmp_dir: dir} do
    assert %{name: "review", actor: :reviewer} = Workflow.Run.step(checkout(dir, 1, 0))
    assert_received {"git", ["merge", "--no-edit", "trunk"]}

    analysis_dir = Path.join([dir, "workflow", "analysis", "t1"])
    project_dir = Path.join(dir, "workflow")
    assert_received {"just", ["certify", run]}
    assert Path.dirname(run) == analysis_dir
    assert_received {:cwd, "just", ["certify", ^run], ^project_dir}
  end

  test "looking at a work says where it is and runs nothing", %{tmp_dir: dir} do
    assert %{step: "certify", actor: :system, done: false, commits: 1, found: %{}} =
             Workflow.Run.look(checkout(dir, 1, 0))

    refute_received {"mix", _args}
    refute_received {"git", ["merge" | _]}
  end

  test "look-steps: criterion 1", %{tmp_dir: dir} do
    assert %{steps: steps} = Workflow.Run.look(checkout(dir, 0, 0))

    assert Enum.map(steps, &Map.take(&1, [:name, :actor])) == [
             %{name: "fix", actor: :coder},
             %{name: "certify", actor: :system},
             %{name: "review", actor: :reviewer},
             %{name: "promote", actor: :system}
           ]
  end

  test "look-steps: criterion 2", %{tmp_dir: dir} do
    assert %{steps: steps} = Workflow.Run.look(checkout(dir, 1, 0))

    assert Enum.map(steps, & &1.state) == ["done", "current", "waiting", "waiting"]
  end

  test "provisioning-is-a-work: criterion 2 - provision/steps names the steps, each run as `just provision <step> <dir>`, and when every one passes the work is done with no agent run",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("kind", "provision")
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))

    File.write!(
      Path.join([dir, "workflow", "provision", "steps"]),
      "install-hooks\nstart-server\n"
    )

    # Every step passes: the stand-in `just` exits 0. Done is nil; no agent step is left.
    assert Workflow.Run.step(work) == nil

    project_dir = Path.join(dir, "workflow")
    assert_received {:cwd, "just", ["provision", "install-hooks", _dir], ^project_dir}
    assert_received {:cwd, "just", ["provision", "start-server", _dir], ^project_dir}
  end

  test "provisioning-is-a-work: criterion 3 - a project with no provision/steps file stops the work and says so",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("kind", "provision")
    File.mkdir_p!(Path.join(dir, "workflow"))

    # Its first step is the system's: it runs after start answers.
    capture_log(fn ->
      assert {%{name: "provision"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert stopped(dir)["reason"] =~ "provision/steps"
    refute_received {:cwd, "just", ["provision" | _], _cwd}
  end

  test "provisioning-is-a-work: criterion 4 - a step's recipe sees the service's environment, and its value appears in no results file, note or log",
       %{tmp_dir: dir} do
    secret = "s3cr3t-token-4f9a"
    System.put_env("PROVISION_TEST_TOKEN", secret)
    on_exit(fn -> System.delete_env("PROVISION_TEST_TOKEN") end)

    work = checkout(dir, 0, 0) |> Map.put("kind", "provision")
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "steps"]), "start-server\n")

    # The recipe sees the variable, and fails printing it, as a careless recipe would.
    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "just", ["provision" | _] = args, opts ->
        stand_in.("just", args, opts)
        {"saw " <> System.get_env("PROVISION_TEST_TOKEN"), 1}

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    log =
      capture_log(fn ->
        send(self(), {:started, Workflow.Run.start(work)})
        settled()
      end)

    assert_received {:started, {step, said}}

    kept =
      for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
          File.regular?(file),
          do: File.read!(file)

    refute Enum.any?([log, inspect(step), inspect(said) | kept], &String.contains?(&1, secret))
  end

  test "provisioning-is-a-work: criterion 5 - a failed step goes to a coder with its note, and once the coder has committed the step passes and the work carries on to the next step",
       %{tmp_dir: dir} do
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "steps"]), "a\nb\n")

    # Step a fails at the first tree, as a stand-in recipe would.
    work = checkout(dir, 0, 0) |> Map.put("kind", "provision")
    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "just", ["provision", "a" | _] = args, opts ->
        stand_in.("just", args, opts)
        {"boom", 1}

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    assert %{name: "fix", actor: :coder, note: note, agent: %{tools: tools}} =
             Workflow.Run.step(work)

    assert note =~ "a: boom"
    assert Enum.sort(tools) == [:bash, :edit, :read, :write]
    refute_received {:cwd, "just", ["provision", "b" | _], _cwd}

    # The coder commits: a new tree, where every step passes, and the fix goes to review.
    work = checkout(dir, 1, 0) |> Map.put("kind", "provision")
    assert %{name: "review"} = Workflow.Run.step(work)
    assert_received {:cwd, "just", ["provision", "a", _dir], _cwd}
    assert_received {:cwd, "just", ["provision", "b", _dir], _cwd}
  end

  test "provisioning-is-a-work: criterion 7 - a provision whose coder committed a fix goes through certify, review and promote, as an issue does",
       %{tmp_dir: dir} do
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "steps"]), "a\n")

    # One commit of its own on the branch, every step passing.
    work = checkout(dir, 1, 0) |> Map.put("kind", "provision")

    assert %{steps: steps} = Workflow.Run.look(work)
    names = Enum.map(steps, & &1.name)
    assert Enum.take(names, -3) == ["certify", "review", "promote"]

    assert %{name: "review", actor: :reviewer} = Workflow.Run.step(work)
    assert_received {"git", ["merge", "--no-edit", "trunk"]}
    assert_received {:cwd, "just", ["certify", _dir], _cwd}
  end

  test "provisioning-is-a-work: criterion 8 - a provision with no commits of its own is simply done, with no certify, review or promote",
       %{tmp_dir: dir} do
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "steps"]), "a\n")

    work = checkout(dir, 0, 0) |> Map.put("kind", "provision")

    assert Workflow.Run.step(work) == nil
    assert_received {:cwd, "just", ["provision", "a", _dir], _cwd}
    refute_received {"just", ["certify" | _]}
    refute_received {"git", ["merge" | _]}
  end

  test "provisioning-is-a-work: criterion 9 - a step that passed is not run again while the tree is unchanged",
       %{tmp_dir: dir} do
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "steps"]), "a\nb\n")

    work = checkout(dir, 0, 0) |> Map.put("kind", "provision")
    stand_in = Application.get_env(:workflow, :cmd)

    # Step a passes, step b fails.
    Application.put_env(:workflow, :cmd, fn
      "just", ["provision", "b" | _] = args, opts ->
        stand_in.("just", args, opts)
        {"boom", 1}

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    assert %{name: "fix"} = Workflow.Run.step(work)
    assert_received {:cwd, "just", ["provision", "a", _dir], _cwd}

    # Looked at again with the tree unchanged: a is not run again.
    assert %{name: "fix"} = Workflow.Run.step(work)
    refute_received {:cwd, "just", ["provision", "a" | _], _cwd}
  end

  test "provision-has-targets: criterion 1", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))

    File.write!(
      Path.join([dir, "workflow", "provision", "uat.steps"]),
      "install-hooks\nstart-server\n"
    )

    File.write!(Path.join([dir, "workflow", "provision", "steps"]), "wrong-step\n")

    work = checkout(dir, 0, 0) |> Map.merge(%{"kind" => "provision", "target" => "uat"})
    stand_in = Application.get_env(:workflow, :cmd)
    test = self()

    Application.put_env(:workflow, :cmd, fn
      "just", ["provision" | _] = args, opts ->
        send(test, {:env, args, Map.new(opts[:env] || [])})
        stand_in.("just", args, opts)

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    assert Workflow.Run.step(work) == nil

    assert_received {:env, ["provision", "install-hooks", _dir], %{"PROVISION_TARGET" => "uat"}}
    assert_received {:env, ["provision", "start-server", _dir], %{"PROVISION_TARGET" => "uat"}}
    refute_received {:env, ["provision", "wrong-step", _dir], _env}
  end

  test "provision-has-targets: criterion 2", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))

    File.write!(
      Path.join([dir, "workflow", "provision", "steps"]),
      "install-hooks\nstart-server\n"
    )

    File.write!(Path.join([dir, "workflow", "provision", "uat.steps"]), "uat-only\n")

    work = checkout(dir, 0, 0) |> Map.put("kind", "provision")

    assert Workflow.Run.step(work) == nil

    project_dir = Path.join(dir, "workflow")
    assert_received {:cwd, "just", ["provision", "install-hooks", _dir], ^project_dir}
    assert_received {:cwd, "just", ["provision", "start-server", _dir], ^project_dir}
    refute_received {:cwd, "just", ["provision", "uat-only", _dir], _cwd}
  end

  test "provision-has-targets: criterion 3", %{tmp_dir: dir} do
    # provision/steps exists, but the target's own file does not: it must not be used instead.
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "steps"]), "install-hooks\n")

    work = checkout(dir, 0, 0) |> Map.merge(%{"kind" => "provision", "target" => "uat"})

    capture_log(fn ->
      assert {%{name: "provision"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert stopped(dir)["reason"] =~ "provision/uat.steps"
    refute_received {:cwd, "just", ["provision" | _], _cwd}
  end

  test "provision-has-targets: a target with no steps file stops the work, naming the file",
       %{tmp_dir: dir} do
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "steps"]), "a\n")

    work = checkout(dir, 0, 0) |> Map.merge(%{"kind" => "provision", "target" => "staging"})

    assert %{name: "fix", note: note} = Workflow.Run.step(work)
    assert note =~ "provision/staging.steps"
    refute_received {:cwd, "just", ["provision" | _], _cwd}
  end

  test "deploy-after-landing: criterion 1", %{tmp_dir: dir} do
    was = Application.get_env(:workflow, :works_dir)
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    on_exit(fn ->
      Application.put_env(:workflow, :works_dir, was)
      Application.delete_env(:workflow, :deploy)
    end)

    File.write!(Path.join(dir, "config.json"), ~s({"deploy": "uat"}))
    assert :ok = Workflow.ConfigFile.load()

    # An issue that passed certify and review lands at tree t1.
    work =
      checkout(dir, 1, 0)
      |> Map.merge(%{"review" => "pass", "repo" => dir, "project" => "workflow"})

    assert Workflow.Run.step(work) == nil
    assert_received {"git", ["merge", "--no-ff", "--no-edit", _commit]}

    # The loop hands in a provision for uat by itself: a checkout cut for an id of uat and t1.
    assert_receive {"git", ["worktree", "add", "-b" | add_args]}, 2_000
    cut = Enum.join(add_args, " ")
    assert cut =~ "uat" and cut =~ "t1"
  end

  test "deploy-after-landing: criterion 2", %{tmp_dir: dir} do
    was = Application.get_env(:workflow, :works_dir)
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    on_exit(fn ->
      Application.put_env(:workflow, :works_dir, was)
      Application.delete_env(:workflow, :deploy)
    end)

    # A config.json with no deploy key.
    File.write!(Path.join(dir, "config.json"), ~s({}))
    assert :ok = Workflow.ConfigFile.load()

    work =
      checkout(dir, 1, 0)
      |> Map.merge(%{"review" => "pass", "repo" => dir, "project" => "workflow"})

    assert Workflow.Run.step(work) == nil
    assert_received {"git", ["merge", "--no-ff", "--no-edit", _commit]}

    # The landing starts nothing: no checkout is cut and no work is in flight.
    refute_receive {"git", ["worktree", "add", "-b" | _]}, 500
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []

    # With deploy set, the same kind of landing hands in a provision for that target and tree.
    File.write!(Path.join(dir, "config.json"), ~s({"deploy": "uat"}))
    Application.delete_env(:workflow, :deploy)
    assert :ok = Workflow.ConfigFile.load()

    assert Workflow.Run.step(Map.put(work, "id", "i2")) == nil
    assert_receive {"git", ["worktree", "add", "-b" | add_args]}, 2_000
    cut = Enum.join(add_args, " ")
    assert cut =~ "uat" and cut =~ "t1"
  end

  test "deploy-after-landing: criterion 3", %{tmp_dir: dir} do
    was = Application.get_env(:workflow, :works_dir)
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    on_exit(fn ->
      Application.put_env(:workflow, :works_dir, was)
      Application.delete_env(:workflow, :deploy)
    end)

    File.write!(Path.join(dir, "config.json"), ~s({"deploy": "uat"}))
    assert :ok = Workflow.ConfigFile.load()

    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "uat.steps"]), "a\n")

    # A provision with a fix of its own, reviewed and passing, lands.
    work =
      checkout(dir, 1, 0)
      |> Map.merge(%{
        "kind" => "provision",
        "target" => "uat",
        "review" => "pass",
        "repo" => dir,
        "project" => "workflow"
      })

    assert Workflow.Run.step(work) == nil
    assert_received {"git", ["merge", "--no-ff", "--no-edit", _commit]}

    # Its landing starts no other provision.
    refute_receive {"git", ["worktree", "add" | _]}, 500
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []
  end

  test "deploy-after-landing: criterion 4", %{tmp_dir: dir} do
    was = Application.get_env(:workflow, :works_dir)
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    on_exit(fn ->
      Application.put_env(:workflow, :works_dir, was)
      Application.delete_env(:workflow, :deploy)
      Application.delete_env(:workflow, :tree)
    end)

    File.write!(Path.join(dir, "config.json"), ~s({"deploy": "uat"}))
    assert :ok = Workflow.ConfigFile.load()

    base =
      checkout(dir, 1, 0)
      |> Map.merge(%{"review" => "pass", "repo" => dir, "project" => "workflow"})

    stand_in = Application.get_env(:workflow, :cmd)
    test = self()
    Application.put_env(:workflow, :tree, "t1")

    # Each landing is at the tree the test names; a provision's checkout has its steps,
    # and its `just provision` waits until the test lets it end.
    Application.put_env(:workflow, :cmd, fn
      "git", ["rev-parse", "HEAD^{tree}"], _opts ->
        {Application.get_env(:workflow, :tree) <> "\n", 0}

      "git", ["worktree", "add", "-b", _branch, path | _at] = args, opts ->
        steps = Path.join([path, "workflow", "provision"])
        File.mkdir_p!(steps)
        File.write!(Path.join(steps, "uat.steps"), "a\n")
        stand_in.("git", args, opts)

      "just", ["provision" | _], opts ->
        send(test, {:provision, opts[:cd], self()})

        receive do
          :go -> {"", 0}
        end

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    land = fn id, tree ->
      Application.put_env(:workflow, :tree, tree)
      assert Workflow.Run.step(Map.put(base, "id", id)) == nil
    end

    land.("i1", "t1")
    assert_receive {:provision, first_cd, first}, 3_000
    assert first_cd =~ "uat-t1"

    # Three landings while it runs: no provision runs beside it.
    land.("i2", "t2")
    land.("i3", "t3")
    land.("i4", "t4")
    refute_receive {:provision, _cd, _pid}, 500

    # When it ends, exactly one more runs, at the newest landed tree.
    send(first, :go)
    assert_receive {:provision, second_cd, second}, 3_000
    assert second_cd =~ "uat-t4"
    send(second, :go)
    refute_receive {:provision, _cd, _pid}, 500
  end

  # A reviewed issue at tree t1, ready to land as commit c1, with deploy set to uat.
  # The stand-in `just ci` exits `ci`, or the project has no ci recipe for `:none`;
  # `sarif` writes the results of each ci run into its folder.
  defp landing(dir, ci, sarif \\ fn _run -> :ok end) do
    was = Application.get_env(:workflow, :works_dir)
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    on_exit(fn ->
      Application.put_env(:workflow, :works_dir, was)
      Application.delete_env(:workflow, :deploy)
    end)

    File.write!(Path.join(dir, "config.json"), ~s({"deploy": "uat"}))
    assert :ok = Workflow.ConfigFile.load()

    work =
      checkout(dir, 1, 0)
      |> Map.merge(%{"review" => "pass", "repo" => dir, "project" => "workflow"})

    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "just", ["--show", "ci"] = args, opts ->
        stand_in.("just", args, opts)
        if ci == :none, do: {"error: Justfile does not contain recipe `ci`", 1}, else: {"", 0}

      # No retry recipe: a failing ci runs once more.
      "just", ["--show", "retry"] = args, opts ->
        stand_in.("just", args, opts)
        {"error: Justfile does not contain recipe `retry`", 1}

      "just", ["ci", run] = args, opts ->
        stand_in.("just", args, opts)
        sarif.(run)
        {"ci: 1 failure", ci}

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    work
  end

  # The manager, configured, with what it is told sent to the test.
  defp manager do
    test = self()

    was =
      for key <- [:manager, :manager_run, :recipients],
          do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Application.delete_env(:workflow, :recipients)

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      send(test, {:manager_told, message})
      {:ok, %{text: "noted", messages: opts[:messages]}}
    end)
  end

  test "ci-gates-uat: criterion 1 - a landing runs `just ci` at exactly the landed commit, in a checkout of its own, keeping its run folder",
       %{tmp_dir: dir} do
    work = landing(dir, 0)
    ci_root = Path.join([dir, "workflow", "ci", "c1"])
    project = Path.join(ci_root, "workflow")

    assert Workflow.Run.step(work) == nil

    # Cut detached at the landed commit, so a later landing does not move it.
    assert_received {"git", ["worktree", "add", "--detach", ^ci_root, "c1"]}
    assert_received {:cwd, "just", ["ci", run], ^project}
    assert Path.dirname(run) == Path.join([dir, "workflow", "analysis", "t1"])
    assert %{"recipe" => "ci", "exit" => 0} = Workflow.Sarif.meta(run)
  end

  test "ci-gates-uat: criterion 1 - a project with no ci recipe counts as green",
       %{tmp_dir: dir} do
    work = landing(dir, :none)

    assert Workflow.Run.step(work) == nil
    assert_received {"just", ["--show", "ci"]}
    refute_received {"just", ["ci", _run]}

    assert_receive {"git", ["worktree", "add", "-b" | add_args]}, 2_000
    assert Enum.join(add_args, " ") =~ "uat-t1"
    assert List.last(add_args) == "c1"
  end

  test "ci-gates-uat: criterion 2 - ci green at the landed commit provisions uat for that commit, and the work ends",
       %{tmp_dir: dir} do
    work = landing(dir, 0)

    assert Workflow.Run.step(work) == nil
    assert_received {"just", ["ci", _run]}

    # The provision's checkout is cut at the landed commit, not at whatever the main copy is at by then.
    assert_receive {"git", ["worktree", "add", "-b" | add_args]}, 2_000
    assert ["provision/uat-t1", _root, "c1"] = add_args
  end

  test "ci-gates-uat: criterion 3 - ci red twice, new with this landing, goes back to the work at its work step with the ci note; nothing is deployed or reverted",
       %{tmp_dir: dir} do
    work = landing(dir, 1)

    assert %{name: "fix", actor: :coder, note: note} = Workflow.Run.step(work)
    assert note =~ "`just ci` failed twice"
    assert note =~ "c1"
    assert note =~ "ci: 1 failure"

    # Run once more before it counted, each run in a folder of its own.
    assert_received {"just", ["ci", first]}
    assert_received {"just", ["ci", second]}
    assert first != second

    refute_receive {"git", ["worktree", "add", "-b" | _]}, 500
    refute_received {"git", ["revert" | _]}
  end

  test "ci-gates-uat: criterion 3 - ci red with the failures the previous dev commit's ci run had reports nothing again",
       %{tmp_dir: dir} do
    manager()
    work = landing(dir, 1)

    # The first landing's red is new: it goes back to that work.
    assert %{name: "fix"} = Workflow.Run.step(work)

    # The next landing is red with the same failures: it ends, and nobody is told.
    assert Workflow.Run.step(Map.put(work, "id", "i2")) == nil
    refute_receive {:manager_told, _notice}, 500
    refute_received {"git", ["worktree", "add", "-b" | _]}
  end

  test "ci-gates-uat: criterion 3 - ci red with failures that belong to no one work tells the manager once, in plain words",
       %{tmp_dir: dir} do
    manager()

    # The previous dev commit's ci run had one of the two failures.
    File.mkdir_p!(Path.join(dir, "workflow"))

    File.write!(
      Path.join([dir, "workflow", "ci-last"]),
      Jason.encode!(%{"commit" => "c0", "failures" => [["exunit", nil, "a fails"]]})
    )

    failing = fn text -> %{"level" => "error", "message" => %{"text" => text}} end

    sarif = fn run ->
      File.write!(
        Path.join(run, "exunit.sarif"),
        Jason.encode!(%{
          "runs" => [
            %{
              "tool" => %{"driver" => %{"name" => "exunit"}},
              "results" => [failing.("a fails"), failing.("b fails")]
            }
          ]
        })
      )
    end

    work = landing(dir, 1, sarif)

    assert Workflow.Run.step(work) == nil
    assert_receive {:manager_told, notice}, 2_000
    assert notice =~ "issue i1"
    assert notice =~ "c1"
    assert notice =~ "Nothing was deployed and nothing was reverted"
    assert notice =~ "b fails"
    refute_receive {:manager_told, _again}, 500
    refute_received {"git", ["worktree", "add", "-b" | _]}
  end

  test "ci-gates-uat: criterion 4 - prod is unchanged: a green landing provisions uat only, and prod waits on the owner's go",
       %{tmp_dir: dir} do
    work = landing(dir, 0)

    assert Workflow.Run.step(work) == nil
    assert_received {"just", ["ci", _run]}

    assert_receive {"git", ["worktree", "add", "-b" | add_args]}, 2_000
    assert ["provision/uat-t1" | _] = add_args
    refute_receive {"git", ["worktree", "add", "-b" | _]}, 500

    File.write!(Path.join(dir, "config.json"), ~s({"deploy": "prod"}))
    assert {:error, why} = Workflow.ConfigFile.load()
    assert why =~ "owner's go"
  end

  test "ci-retries-with-a-retry-recipe: criterion 3 - a landing whose ci fails and whose retry passes names the flaky test to the manager and in the work's report to the server",
       %{tmp_dir: dir} do
    manager()

    sarif = fn run ->
      File.write!(
        Path.join(run, "exunit.sarif"),
        Jason.encode!(%{
          "runs" => [
            %{
              "tool" => %{"driver" => %{"name" => "exunit"}},
              "results" => [
                %{
                  "level" => "error",
                  "message" => %{"text" => "test a flaky one (ATest)\nassert false"},
                  "locations" => [
                    %{
                      "physicalLocation" => %{"artifactLocation" => %{"uri" => "test/a_test.exs"}}
                    }
                  ]
                }
              ]
            }
          ]
        })
      )
    end

    work = landing(dir, 1, sarif)
    test = self()
    inner = Application.get_env(:workflow, :cmd)

    # The project has a retry recipe, and its retry passes.
    Application.put_env(:workflow, :cmd, fn
      "just", ["--show", "retry"], _opts -> {"retry dir first:", 0}
      "just", ["retry", _run, _first] = args, _opts -> send(test, {"just", args}) && {"", 0}
      command, args, opts -> inner.(command, args, opts)
    end)

    # The test stands in for the loop's line to the server.
    Process.register(self(), Workflow.Server)

    assert Workflow.Run.step(work) == nil
    assert_received {"just", ["ci", first]}
    assert_received {"just", ["retry", second, ^first]}
    assert first != second
    refute_received {"just", ["ci", _again]}

    flake = %{"file" => "test/a_test.exs", "test" => "test a flaky one (ATest)"}
    assert_receive {:report, %{"work" => "i1", "flakes" => [^flake]}}, 3_000

    assert_receive {:manager_told, told}, 3_000
    assert told =~ "test/a_test.exs: test a flaky one (ATest)"

    # Green: deployed as any green landing is.
    assert_receive {"git", ["worktree", "add", "-b", "provision/uat-t1" | _]}, 2_000
  end

  test "look-steps: criterion 3", %{tmp_dir: dir} do
    work = checkout(dir, 0, 0)

    path = Path.join([dir, "workflow", "i1.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "t0" => %{
          "certify" => %{"status" => "passed"},
          "review" => %{"status" => "pass"},
          "promote" => %{"status" => "promoted"}
        }
      })
    )

    assert %{done: true, steps: steps} = Workflow.Run.look(work)
    assert Enum.all?(steps, &(&1.state == "done"))
  end

  test "looking at a story with no criteria of its own reads them from what was kept beside its results",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.merge(%{"kind" => "story", "root" => dir})

    path = Path.join([dir, "workflow", "i1.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{"work" => Map.put(work, "criteria", ["the user logs in"])})
    )

    asked = %{"kind" => "story", "id" => "i1", "root" => dir}
    assert %{step: "specify", actor: :qa, done: false} = Workflow.Run.look(asked)
  end

  test "a provider that errors twice in a row leaves the work parked, with one warning naming the step and the error",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    test = self()

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:ran, step.name})
      {%{}, "boom"}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    log =
      capture_log(fn ->
        assert {%{name: "fix", actor: :coder}, "started"} = Workflow.Run.start(work)
        assert_receive {:ran, "fix"}
        assert_receive {:ran, "fix"}
        settled()
        refute_received {:ran, "fix"}
      end)

    assert log =~ "fix parked"
    assert log =~ "boom"
  end

  test "a provider that errors once is told the turn again, and nothing is parked once the retry succeeds",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    test = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      n = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
      send(test, {:ran, step.name, n})
      if n == 1, do: {%{}, "boom"}, else: {%{}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    log =
      capture_log(fn ->
        assert {%{name: "fix", actor: :coder}, "started"} = Workflow.Run.start(work)
        assert_receive {:ran, "fix", 1}
        assert_receive {:ran, "fix", 2}
        # Run on after that, told again, since its turns move nothing; never parked.
        settled()
      end)

    refute log =~ "parked"
  end

  test "agents-commit-no-ignored-files: a tree dirty only in tracked ignored paths tells the agent which, and to git rm --cached them",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    test = self()
    {:ok, turns} = Agent.start_link(fn -> 0 end)
    cmd = Application.get_env(:workflow, :cmd)

    # After the first turn the force-added scratch file is rewritten.
    Application.put_env(:workflow, :cmd, fn
      "git", ["status" | _], opts ->
        if Agent.get(turns, & &1) > 0,
          do: {" M tmp/scratch.txt\n", 0},
          else: cmd.("git", ["status"], opts)

      "git", ["ls-files" | _], _opts ->
        {"tmp/scratch.txt\n", 0}

      command, args, opts ->
        cmd.(command, args, opts)
    end)

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      Agent.update(turns, &(&1 + 1))
      send(test, {:ran, step.note})
      {%{}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    {second, _log} =
      with_log(fn ->
        assert {%{name: "fix", actor: :coder}, "started"} = Workflow.Run.start(work)
        assert_receive {:ran, _first}
        assert_receive {:ran, second}, 500
        settled()
        second
      end)

    assert second =~ "tmp/scratch.txt"
    assert second =~ ".gitignore"
    assert second =~ "git rm --cached"
    refute second =~ "You left changes uncommitted"
  end

  test "no-stalls: criterion 1 - an agent whose turn changes nothing is told again instead of being left",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    test = self()

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:ran, step.note})
      {%{}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    assert {%{name: "fix", actor: :coder}, "started"} = Workflow.Run.start(work)

    # Waited on the run ending (its watch waits on its turns), not on a clock: a
    # loaded suite took longer than a receive's deadline between the turns.
    capture_log(&settled/0)

    assert_received {:ran, first_note}
    # Nothing moved: same step, same note. The agent should be told again, not left.
    assert_received {:ran, second_note}

    refute second_note == first_note
    assert second_note =~ first_note
    assert second_note =~ ~r/nothing (moved|changed)/i
  end

  test "no-stalls: criterion 2 - an agent whose run errors twice is recorded as stopped with its step, reason and time, and logged once",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})

    Application.put_env(:workflow, :agents_run, fn _step, _work -> {%{}, "boom"} end)
    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    log =
      capture_log(fn ->
        assert {%{name: "fix", actor: :coder}, "started"} = Workflow.Run.start(work)
        settled()
      end)

    results = Path.join([dir, "workflow", "i1.json"]) |> File.read!() |> Jason.decode!()

    assert %{"step" => "fix", "reason" => reason, "at" => at} = results["stopped"]
    assert reason =~ "boom"
    assert is_binary(at)

    assert length(Regex.scan(~r/\[warning\]/, log)) == 1
  end

  test "no-stalls: criterion 3 - a work whose turns process goes down is recorded as stopped with that reason and its checkout's lock is free",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})

    Application.put_env(:workflow, :agents_run, fn _step, _work -> exit(:kaboom) end)
    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      assert {%{name: "fix", actor: :coder}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    results = Path.join([dir, "workflow", "i1.json"]) |> File.read!() |> Jason.decode!()

    assert %{"step" => "fix", "reason" => reason, "at" => at} = results["stopped"]
    assert reason =~ "kaboom"
    assert is_binary(at)

    # The lock is the checkout's: it can be taken again now the holder is gone.
    assert :global.trans({{Workflow.Run, dir}, self()}, fn -> :free end, [node()], 0) ==
             :free
  end

  test "no-stalls: criterion 4 - a work whose turns were started is kept in works_dir without its key, and removed once it is stopped",
       %{tmp_dir: dir} do
    works_dir = works_dir(dir)

    work =
      checkout(dir, 0, 0)
      |> Map.put("agent", %{"provider" => "claude-code", "key" => "sekret"})

    test = self()

    file = Path.join(works_dir, "i1.json")

    # Each run looks at the file while the work is in flight, and sends what it found.
    Application.put_env(:workflow, :agents_run, fn _step, _work ->
      send(test, {:ran, File.read(file)})
      {%{}, "boom"}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      assert {%{name: "fix", actor: :coder}, "started"} = Workflow.Run.start(work)
      # Waited on the run ending (its watch waits on its turns), not on a clock.
      settled()
    end)

    for _run <- 1..2 do
      assert_received {:ran, {:ok, kept}}
      assert %{"id" => "i1", "agent" => agent} = Jason.decode!(kept)
      assert agent == %{"provider" => "claude-code"}
      refute kept =~ "sekret"
    end

    # Stopped: no longer in flight, so nothing to resume.
    refute File.exists?(file)
  end

  test "system-steps-outlive-their-caller: a system step goes on, kept in flight, after the process that handed the work in is killed",
       %{tmp_dir: dir} do
    works_dir = works_dir(dir)
    work = checkout(dir, 1, 0)
    stand_in = Application.get_env(:workflow, :cmd)
    test = self()

    # Its certify waits until the test lets it end.
    Application.put_env(:workflow, :cmd, fn
      "just", ["certify" | _], _opts ->
        send(test, {:certifying, self()})
        receive do: (:go -> {"1 test", 0})

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    capture_log(fn ->
      caller =
        spawn(fn ->
          send(test, {:answered, Workflow.Run.start(work)})
          receive do: (:never -> :ok)
        end)

      assert_receive {:answered, {%{name: "certify", actor: :system}, "started"}}
      assert_receive {:certifying, certifying}, 2_000
      Process.exit(caller, :kill)

      # In flight and at work while it runs, so a restart would resume it.
      assert File.exists?(Path.join(works_dir, "i1.json"))
      assert %{working: true} = Workflow.Run.look(work)

      ref = Process.monitor(certifying)
      send(certifying, :go)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000
    end)

    assert %{"status" => "passed"} = Workflow.Run.look(work).found["certify"]
    assert %{step: "review", working: false} = Workflow.Run.look(work)
    refute File.exists?(Path.join(works_dir, "i1.json"))
  end

  test "system-steps-outlive-their-caller: a system step that raises leaves the work stopped with the reason",
       %{tmp_dir: dir} do
    works_dir(dir)
    work = checkout(dir, 1, 0)
    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "just", ["certify" | _], _opts -> raise "certify blew up"
      command, args, opts -> stand_in.(command, args, opts)
    end)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert %{"step" => "certify", "reason" => reason} = stopped(dir)
    assert reason =~ "certify blew up"
  end

  test "system-steps-outlive-their-caller: each event is a line in the log beside the tree's SARIF files, whose path look answers",
       %{tmp_dir: dir} do
    works_dir(dir)
    work = checkout(dir, 1, 0)
    log = Path.join([dir, "workflow", "analysis", "t1", "log"])

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      assert Workflow.Run.log(work) == log
      settled()
    end)

    lines = log |> File.read!() |> String.split("\n", trim: true)
    said = Enum.map(lines, &(&1 |> String.split(" ", parts: 2) |> List.last()))

    assert "handed in" in said
    assert "certify started" in said
    assert Enum.any?(said, &(&1 =~ ~r/^just certify: exit 0 in \d+ms$/))
    assert "certify: passed" in said
    assert List.last(said) =~ "waiting on its owner at review"
    assert %{log: ^log, working: false} = Workflow.Run.look(work)
  end

  test "system-steps-outlive-their-caller: after an agent's commit the log goes on in the new tree's folder, and the old log's last line names it",
       %{tmp_dir: dir} do
    works_dir(dir)
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    {:ok, turns} = Agent.start_link(fn -> 0 end)
    cmd = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "git", ["rev-parse", "HEAD^{tree}"], _opts -> {"t0-#{Agent.get(turns, & &1)}\n", 0}
      command, args, opts -> cmd.(command, args, opts)
    end)

    # The first turn moves the tree; the turns after it end in error, so the work stops.
    Application.put_env(:workflow, :agents_run, fn _step, _work ->
      case Agent.get_and_update(turns, &{&1, min(&1 + 1, 1)}) do
        0 -> {%{"note" => "fixed it"}, nil}
        _moved -> {%{}, "boom"}
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    old = Path.join([dir, "workflow", "analysis", "t0-0", "log"])
    new = Path.join([dir, "workflow", "analysis", "t0-1", "log"])

    capture_log(fn ->
      assert {%{name: "fix"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    old_lines = old |> File.read!() |> String.split("\n", trim: true)
    assert Enum.any?(old_lines, &(&1 =~ "fix started (coder)"))
    assert List.last(old_lines) =~ "the tree moved to t0-1: the log goes on in #{new}"

    new_lines = new |> File.read!() |> String.split("\n", trim: true)
    assert hd(new_lines) =~ "fix turn by the coder ended: fixed it"
    assert List.last(new_lines) =~ "stopped at fix: parked"
    assert %{log: ^new} = Workflow.Run.look(work)
  end

  test "prod-waits-for-the-owner: criterion 1 - a provision for prod handed in runs none of its steps and look says it waits for the owner's go, naming the tree",
       %{tmp_dir: dir} do
    works_dir(dir)
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "prod.steps"]), "a\nb\n")
    work = checkout(dir, 0, 0) |> Map.merge(%{"kind" => "provision", "target" => "prod"})

    capture_log(fn ->
      Workflow.Run.start(work)
      settled()
    end)

    refute_received {:cwd, "just", ["provision" | _], _cwd}

    assert %{done: false, note: note} = Workflow.Run.look(work)
    assert note =~ "owner's go"
    assert note =~ "t0"
  end

  test "prod-waits-for-the-owner: criterion 2 - a prod provision handed in with no earlier prod provision passed waits for the owner's go and names the tree",
       %{tmp_dir: dir} do
    works_dir(dir)
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "prod.steps"]), "a\n")
    work = checkout(dir, 1, 0) |> Map.merge(%{"kind" => "provision", "target" => "prod"})

    capture_log(fn ->
      Workflow.Run.start(work)
      settled()
    end)

    refute_received {:cwd, "just", ["provision" | _], _cwd}

    assert %{done: false, step: "go", note: note} = Workflow.Run.look(work)
    assert note =~ "owner's go"
    assert note =~ "t1"
  end

  test "prod-waits-for-the-owner: criterion 1 - a waiting prod provision names the commits since the last prod provision that passed, and one passing becomes the last",
       %{tmp_dir: dir} do
    works_dir(dir)
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "prod.steps"]), "a\n")
    work = checkout(dir, 0, 0) |> Map.merge(%{"kind" => "provision", "target" => "prod"})
    cmd = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "git", ["log", "--oneline", "c0..HEAD"], _opts -> {"c2 add billing\nc1 fix login\n", 0}
      command, args, opts -> cmd.(command, args, opts)
    end)

    # An earlier prod provision passes at c0, on the owner's go.
    capture_log(fn ->
      Workflow.Run.start(work)
      settled()
      Workflow.Checkout.record(dir, work["id"], "go", %{"status" => "go"})
      Workflow.Run.start(work)
      settled()
    end)

    assert_received {:cwd, "just", ["provision", "a", _dir], _cwd}

    # A new prod provision, handed in later, names what it would add.
    later = Map.put(work, "id", "prod-2")

    capture_log(fn ->
      Workflow.Run.start(later)
      settled()
    end)

    assert %{step: "go", note: note} = Workflow.Run.look(later)
    assert note =~ "t0"
    assert note =~ "c1 fix login"
    assert note =~ "c2 add billing"
  end

  # Works in flight kept under the test's own directory, put back as configured after.
  defp works_dir(dir) do
    works_dir = Path.join(dir, "works")
    was = Application.get_env(:workflow, :works_dir)
    Application.put_env(:workflow, :works_dir, works_dir)
    on_exit(fn -> Application.put_env(:workflow, :works_dir, was) end)
    works_dir
  end

  # Waits until every process a call in this test left running in the background
  # (a work's turns, their watcher, a resume) has gone down. Each says who started
  # it in `$callers`; one linked to the test lives as long as the test, so is not waited on.
  defp settled do
    {:links, links} = Process.info(self(), :links)

    case Enum.filter(Process.list(), &(&1 not in links and called_by_test?(&1))) do
      [] ->
        :ok

      pids ->
        for pid <- pids do
          ref = Process.monitor(pid)
          receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
        end

        settled()
    end
  end

  defp called_by_test?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> self() in Keyword.get(dictionary, :"$callers", [])
      nil -> false
    end
  end

  defp in_flight(works_dir, work) do
    File.mkdir_p!(works_dir)
    File.write!(Path.join(works_dir, "#{work["id"]}.json"), Jason.encode!(work))
    Path.join(works_dir, "#{work["id"]}.json")
  end

  defp stopped(dir),
    do: (Path.join([dir, "workflow", "i1.json"]) |> File.read!() |> Jason.decode!())["stopped"]

  test "no-stalls: criterion 2 - an agent still on its step when the handoffs are spent is stopped",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    test = self()

    # Each turn leaves a new tree with no commit on the branch, so it is never the same step sent again.
    {:ok, turns} = Agent.start_link(fn -> 0 end)
    cmd = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "git", ["rev-parse", "HEAD^{tree}"], _opts -> {"t0-#{Agent.get(turns, & &1)}\n", 0}
      command, args, opts -> cmd.(command, args, opts)
    end)

    Application.put_env(:workflow, :agents_run, fn _step, _work ->
      send(test, :ran)
      Agent.update(turns, &(&1 + 1))
      {%{}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      assert {%{name: "fix"}, "started"} = Workflow.Run.start(work)
      settled()
      # The first turn, then one per handoff.
      for _ <- 1..31, do: assert_received(:ran)
      refute_received :ran
    end)

    assert %{"step" => "fix", "reason" => reason} = stopped(dir)
    assert reason =~ "handoffs"
  end

  test "same-step: a step sent to the same agent a third time with the same tree and note is not sent; the work waits and says why",
       %{tmp_dir: dir} do
    file = Path.join(works_dir(dir), "i1.json")
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    test = self()

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:ran, step.name})
      {%{}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    log =
      capture_log(fn ->
        assert {%{name: "fix"}, "started"} = Workflow.Run.start(work)
        settled()
      end)

    assert_received {:ran, "fix"}
    assert_received {:ran, "fix"}
    refute_received {:ran, _}

    assert %{"step" => "fix", "reason" => reason} = stopped(dir)
    assert reason =~ "waiting on its owner"
    assert reason =~ "third time"
    assert %{stopped: %{"reason" => ^reason}} = Workflow.Run.look(work)
    assert log =~ "waiting on its owner"
    # Waiting: no longer in flight, so a restart does not send it again.
    refute File.exists?(file)
  end

  test "unchanged-tree-rechecks-once: criteria 1 to 3 - a coder's fix turn that leaves a failed check's tree unchanged has the check run once more there; a pass moves on named as a flake, a second failure waits as today",
       %{tmp_dir: dir} do
    manager()
    works_dir(dir)
    test = self()

    # The coder finds nothing to change: every turn leaves the tree as it was.
    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:ran, step.name})
      {%{}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    told = fn told ->
      receive do
        {:manager_told, message} -> [message | told.(told)]
      after
        1_000 -> []
      end
    end

    # Certify is red at tree t1 (its recipe failing twice); run again there, it exits `again`.
    for {again, at} <- [{0, "passes"}, {1, "fails"}] do
      root = Path.join(dir, at)
      File.mkdir_p!(root)
      work = checkout(root, 1, 1) |> Map.put("agent", %{"provider" => "claude-code"})
      stand_in = Application.get_env(:workflow, :cmd)
      {:ok, runs} = Agent.start_link(fn -> 0 end)

      Application.put_env(:workflow, :cmd, fn
        "just", ["certify", _run] = args, opts ->
          stand_in.("just", args, opts)
          n = Agent.get_and_update(runs, &{&1 + 1, &1 + 1})
          {"1204 tests", if(n <= 2, do: 1, else: again)}

        command, args, opts ->
          stand_in.(command, args, opts)
      end)

      capture_log(fn ->
        assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
        settled()
      end)

      said = told.(told)

      # One fix turn, then the check once more, at the same tree, instead of the same note again.
      assert_received {:ran, "fix"}
      refute_received {:ran, "fix"}

      runs_at_t1 =
        Path.wildcard(Path.join([root, "workflow", "analysis", "t1", "*", "meta.json"]))

      assert length(runs_at_t1) == Agent.get(runs, & &1)

      flaky =
        "was flaky: `just certify` failed, then `just certify` passed at the same tree"

      if again == 0 do
        assert Agent.get(runs, & &1) == 3
        assert_received {:ran, "review"}
        assert Enum.any?(said, &(&1 =~ flaky))
        # The stand-in reviewer moves nothing, so it is sent again: those turns are this phase's.
        receive_all = fn again ->
          receive do: ({:ran, "review"} -> again.(again)), after: (0 -> :ok)
        end

        receive_all.(receive_all)
      else
        # Red twice again: no more runs, and the work waits as a third send does today.
        assert Agent.get(runs, & &1) == 4
        refute_received {:ran, "review"}
        refute Enum.any?(said, &(&1 =~ flaky))
        assert %{"step" => "fix", "reason" => reason} = stopped(root)

        assert reason =~
                 "waiting on its owner: sent to the coder a third time with the same tree and note"
      end
    end
  end

  test "a-turn-with-no-change-keeps-its-words: criteria 1 and 2 - a coder turn that changes nothing has its final text in the log and in the stop note",
       %{tmp_dir: dir} do
    works_dir(dir)
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    words = "I made no change: the test already passes."

    # The agent itself is faked at Alloy, so its final text goes the whole way.
    Application.put_env(:workflow, :alloy_run, fn _prompt, _opts ->
      {:ok, %{status: :completed, turns: 1, text: words, messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :alloy_run) end)

    capture_log(fn ->
      assert {%{name: "fix"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    said = Workflow.Run.log(work) |> File.read!()
    assert said =~ "fix turn by the coder ended: #{words}"

    assert %{"step" => "fix", "reason" => reason} = stopped(dir)
    assert reason =~ "third time"
    assert reason =~ words
  end

  test "provisioning-is-a-work: criterion 6 - a step that fails three times with nothing changed is not sent a third time; the work waits and says why",
       %{tmp_dir: dir} do
    file = Path.join(works_dir(dir), "i1.json")
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "steps"]), "a\n")

    work =
      checkout(dir, 0, 1)
      |> Map.merge(%{"kind" => "provision", "agent" => %{"provider" => "claude-code"}})

    test = self()

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:ran, step.name})
      {%{}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      assert {%{name: "provision"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert_received {:ran, "fix"}
    assert_received {:ran, "fix"}
    refute_received {:ran, _}

    assert %{"step" => "fix", "reason" => reason} = stopped(dir)
    assert reason =~ "waiting on its owner"
    assert reason =~ "third time"
    refute File.exists?(file)
  end

  test "deploy-after-landing: criterion 5", %{tmp_dir: dir} do
    test = self()
    works_dir(dir)
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "uat.steps"]), "a\n")

    # A deploy provision whose step keeps failing, the tree never changing.
    work =
      checkout(dir, 0, 1)
      |> Map.merge(%{
        "kind" => "provision",
        "id" => "uat-t0",
        "target" => "uat",
        "agent" => %{"provider" => "claude-code"}
      })

    was =
      for key <- [:manager, :manager_run, :recipients],
          do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end

      Application.delete_env(:workflow, :agents_run)
    end)

    Application.delete_env(:workflow, :recipients)

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      send(test, {:manager_told, message})
      {:ok, %{text: "noted", messages: opts[:messages]}}
    end)

    Application.put_env(:workflow, :agents_run, fn _step, _work -> {%{}, nil} end)

    capture_log(fn ->
      assert {%{name: "provision"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    # It waits, with the reason kept, and the manager is told as for any waiting work.
    assert %{"reason" => reason} = Workflow.Checkout.stopped(dir, "uat-t0")
    assert reason =~ "waiting on its owner"
    assert_receive {:manager_told, notice}, 2_000
    assert notice =~ "provision uat-t0"
    assert notice =~ "waiting on its owner"
  end

  test "no-stalls: criterion 2 - handing a stopped work in again removes stopped", %{
    tmp_dir: dir
  } do
    work = checkout(dir, 0, 0)
    Workflow.Checkout.stop(dir, "i1", "fix", "gave up")
    assert %{"reason" => "gave up"} = Workflow.Checkout.stopped(dir, "i1")
    assert %{stopped: %{"reason" => "gave up"}} = Workflow.Run.look(work)

    Workflow.Run.step(work)

    assert Workflow.Checkout.stopped(dir, "i1") == nil
    refute Map.has_key?(Workflow.Run.look(work), :stopped)
  end

  test "hand-in-again: a work handed in again at an unchanged tree runs its checks afresh, not the kept failure",
       %{tmp_dir: dir} do
    # The checks fail from the environment, and the work goes back to the coder.
    work = checkout(dir, 1, 1)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert %{name: "fix", note: note} = Workflow.Run.step(work)
    assert note =~ "3 tests, 1 failure"
    Workflow.Checkout.stop(dir, "i1", "fix", "gave up")

    # The environment is fixed; the tree is the same. Handed in again, it is checked again.
    work = checkout(dir, 1, 0)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert %{name: "review", actor: :reviewer} = Workflow.Run.step(work)
    assert_received {"just", ["certify", _analysis_dir]}
    assert Workflow.Checkout.stopped(dir, "i1") == nil
    assert %{"status" => "passed"} = Workflow.Run.look(work).found["certify"]
  end

  test "no-stalls: criterion 4 - a work whose turns end done is no longer kept in flight",
       %{tmp_dir: dir} do
    file = Path.join(works_dir(dir), "i1.json")
    work = checkout(dir, 1, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    test = self()

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:ran, step.name})
      {%{"status" => "pass"}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      assert_receive {:ran, "review"}, 2_000
      settled()
    end)

    assert Workflow.Run.step(work) == nil
    refute File.exists?(file)
    assert stopped(dir) == nil
  end

  test "browser-for-pages: criterion 4 a work that ends closes its browser session once, with the work's id",
       %{tmp_dir: dir} do
    work = checkout(dir, 1, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    test = self()
    others = Application.get_env(:workflow, :cmd)

    # Answers agent-browser itself, so no real browser is needed; the rest goes on as before.
    Application.put_env(:workflow, :cmd, fn
      "agent-browser", args, opts ->
        send(test, {:browser, args, opts})
        {"", 0}

      command, args, opts ->
        others.(command, args, opts)
    end)

    Application.put_env(:workflow, :agents_run, fn _step, _work ->
      {%{"status" => "pass"}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert_received {:browser, args, opts}
    assert "close" in args

    assert "i1" in args or
             opts[:env] |> List.wrap() |> Enum.member?({"AGENT_BROWSER_SESSION", "i1"})

    refute_received {:browser, _args, _opts}
  end

  # Seen live: "spawn: Could not cd to <the work's checkout>" after a work landed:
  # the manager, told it was done, looked at it in the checkout already taken away.
  test "looking at a work whose checkout was removed when it landed runs nothing from that checkout",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    work = checkout(dir, 1, 0, repo: repo)
    test = self()
    others = Application.get_env(:workflow, :cmd)

    # Removing the checkout takes its directory away, as git does; a command run
    # from a directory that is not there is what spawn cannot cd to.
    Application.put_env(:workflow, :cmd, fn
      "git", ["worktree", "remove", root] = args, opts ->
        File.rm_rf!(root)
        others.("git", args, opts)

      command, args, opts ->
        if is_binary(opts[:cd]) and not File.dir?(opts[:cd]),
          do: send(test, {:missing_cd, command, args, opts[:cd]})

        others.(command, args, opts)
    end)

    capture_log(fn -> assert Workflow.Run.step(Map.put(work, "review", "pass")) == nil end)
    assert_received {"git", ["worktree", "remove" | _]}
    refute File.exists?(Workflow.Checkout.root(repo, "i1"))

    # Flushed: only what runs after the work has landed is in question.
    receive_all = fn f -> receive do: (_ -> f.(f)), after: (0 -> :ok) end
    receive_all.(receive_all)

    # The manager, told the work is done, looks at it in the checkout beside its repo.
    look = Enum.find(Workflow.Manager.tools(%{"repo" => repo}), &(&1.name == "look"))

    assert {:ok, "There is no checkout for i1."} =
             look.execute.(%{"id" => "i1", "kind" => "issue"}, %{})

    refute_received {:missing_cd, _command, _args, _cd}
  end

  test "browser-for-pages: criterion 5 a work still ends as it would have when agent-browser is not installed",
       %{tmp_dir: dir} do
    file = Path.join(works_dir(dir), "i1.json")
    work = checkout(dir, 1, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    others = Application.get_env(:workflow, :cmd)

    # What System.cmd does for a command that is not on the machine.
    Application.put_env(:workflow, :cmd, fn
      "agent-browser", _args, _opts -> raise ErlangError, original: :enoent
      command, args, opts -> others.(command, args, opts)
    end)

    Application.put_env(:workflow, :agents_run, fn _step, _work ->
      {%{"status" => "pass"}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert Workflow.Run.step(work) == nil
    refute File.exists?(file)
    assert stopped(dir) == nil
  end

  test "no-stalls: criterion 4 - a work whose turns leave it waiting on its owner is no longer kept in flight",
       %{tmp_dir: dir} do
    file = Path.join(works_dir(dir), "i1.json")
    work = journey(dir) |> Map.put("agent", %{"provider" => "claude-code"})
    test = self()

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:ran, step.name})
      {%{"status" => "pass"}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      assert {%{name: "run"}, "started"} = Workflow.Run.start(work)
      assert_receive {:ran, "review"}, 2_000
      settled()
    end)

    assert %{actor: :owner} = Workflow.Run.step(work)
    refute File.exists?(file)
    assert stopped(dir) == nil
  end

  test "no-stalls: criterion 4 - a work that starts no turns, its checkout's lock being held, is not kept in flight",
       %{tmp_dir: dir} do
    file = Path.join(works_dir(dir), "i1.json")
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    Application.put_env(:workflow, :agents_run, fn _step, _work -> {%{}, nil} end)
    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    held =
      :global.trans(
        {{Workflow.Run, dir}, self()},
        fn ->
          capture_log(fn ->
            assert {%{name: "fix"}, "started"} = Workflow.Run.start(work)
            settled()
          end)

          File.exists?(file)
        end,
        [node()],
        0
      )

    assert held == false
  end

  test "no-stalls: criterion 4 - resume starts again each work kept in flight", %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "claude-code"})
    file = in_flight(works_dir(dir), work)
    test = self()

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:ran, step.name})
      {%{}, "boom"}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      assert Workflow.Run.resume() == :ok
      assert_receive {:ran, "fix"}, 500
      settled()
    end)

    # It ran again, errored twice, and was stopped: nothing left to resume.
    assert %{"step" => "fix"} = stopped(dir)
    refute File.exists?(file)
  end

  test "a work resumed on uncommitted changes with no agent at work is stopped, not dropped",
       %{tmp_dir: dir} do
    # No agent to give the tree to: one that has an agent goes to its coder instead
    # (see a_killed_turn_does_not_strand_its_work_test.exs).
    work = checkout(dir, 1, 0)
    cmd = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "git", ["status" | _], _opts -> {" M lib/a.ex\n", 0}
      command, args, opts -> cmd.(command, args, opts)
    end)

    file = in_flight(works_dir(dir), work)

    capture_log(fn -> assert Workflow.Run.resume() == :ok end)

    assert %{"reason" => reason} = stopped(dir)
    assert reason =~ "uncommitted"
    refute File.exists?(file)
  end

  test "no-stalls: criterion 4 - a resumed work whose agent's key is gone is stopped with that reason",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "anthropic"})
    file = in_flight(works_dir(dir), work)

    capture_log(fn -> assert Workflow.Run.resume() == :ok end)

    assert %{"step" => "fix", "reason" => reason} = stopped(dir)
    assert reason =~ "key"
    refute File.exists?(file)
  end

  test "no-stalls: criterion 4 - the application resumes works in flight only when a port is configured",
       %{tmp_dir: dir} do
    work = checkout(dir, 0, 0) |> Map.put("agent", %{"provider" => "anthropic"})
    file = in_flight(works_dir(dir), work)
    on_exit(fn -> Application.delete_env(:workflow, :port) end)

    # Already running, its supervisor is not started twice; what matters is the resume.
    capture_log(fn ->
      Application.delete_env(:workflow, :port)
      Workflow.Application.start(:normal, [])
      settled()
    end)

    assert File.exists?(file)

    capture_log(fn ->
      Application.put_env(:workflow, :port, 4999)
      Workflow.Application.start(:normal, [])
      settled()
    end)

    refute File.exists?(file)
  end

  test "met-needs-a-test: qa calling a later criterion already met with no commit of its turn is sent back to that criterion",
       %{tmp_dir: dir} do
    # Two commits on the branch already: criterion 1's test and its code, run and passed.
    test_dir = Path.join([dir, "workflow", "test"])
    File.mkdir_p!(test_dir)
    File.write!(Path.join(test_dir, "story_test.exs"), "test \"i1: criterion 1\" do\nend\n")

    File.write!(
      Path.join([dir, "workflow", "i1.json"]),
      Jason.encode!(%{"t2" => %{"run" => %{"status" => "passed"}, "by" => %{"step" => "work"}}})
    )

    work =
      checkout(dir, 2, 0)
      |> Map.merge(%{
        "kind" => "story",
        "criteria" => ["a", "b"],
        "agent" => %{"provider" => "claude-code"}
      })

    test = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    # qa writes criterion 2's test but commits nothing (the branch stays at two
    # commits), and calls it already met. Any later turn errors, to end the run.
    # Only this test's work is counted: a turn another test left running calls the
    # same stand-in, and would take this one's first turn.
    Application.put_env(:workflow, :agents_run, fn
      step, %{"root" => ^dir} ->
        n = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
        send(test, {:ran, n, step.name, step[:stage]})

        if n == 1 do
          File.write!(
            Path.join(test_dir, "story_test.exs"),
            "test \"i1: criterion 1\" do\nend\ntest \"i1: criterion 2\" do\nend\n"
          )

          {%{"status" => "pass", "note" => "already met"}, nil}
        else
          {%{}, "boom"}
        end

      _step, _other_work ->
        {%{}, "boom"}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    # The run ends on its own (later turns error), so it is waited on with no
    # deadline: its first turn starts in the background, which a loaded machine
    # can hold back past any timed wait.
    capture_log(fn ->
      assert {%{name: "run"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert_received {:ran, 1, "specify", 2}
    assert_received {:ran, 2, next, stage}
    assert {next, stage} == {"specify", 2}
  end

  test "a failed check goes back to the coder with its output", %{tmp_dir: dir} do
    assert %{name: "fix", note: note} = Workflow.Run.step(checkout(dir, 1, 1))
    assert note =~ "3 tests, 1 failure"
  end

  test "a passed review merges it into the main copy; a failed one goes back", %{tmp_dir: dir} do
    work = checkout(dir, 1, 0)

    assert %{name: "fix", note: "The review failed: no test"} =
             Workflow.Run.step(Map.merge(work, %{"review" => "fail", "note" => "no test"}))

    assert Workflow.Run.step(Map.put(work, "review", "pass")) == nil

    assert_received {"git", ["merge", "--no-ff", "--no-edit", "c1"]}
  end

  test "sarif: criterion 3", %{tmp_dir: dir} do
    test = self()

    Application.put_env(:workflow, :cmd, fn command, args, call_opts ->
      case {command, args} do
        {"git", ["rev-parse", "HEAD^{tree}"]} ->
          {"t0\n", 0}

        {"git", ["worktree" | _]} ->
          {"worktree /main copy\nHEAD abc\n", 0}

        {"git", ["rev-parse", "--abbrev-ref", "HEAD"]} ->
          {"trunk\n", 0}

        {"git", ["rev-list" | _]} ->
          {"0\n", 0}

        {"git", ["status" | _]} ->
          {"", 0}

        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} ->
          {dir <> "\n", 0}

        # A story handed in is committed as stories/<id>.yml.
        {"git", [command | _]} when command in ["add", "commit"] ->
          {"", 0}

        {"just", ["run", analysis_dir]} ->
          send(test, {:just, "run", analysis_dir, call_opts[:cd]})
          # What real `just` says when the project has no such recipe.
          {"error: justfile does not contain recipe `run`\n", 1}
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    test_dir = Path.join([dir, "myproj", "test"])
    File.mkdir_p!(test_dir)
    File.write!(Path.join(test_dir, "story_test.exs"), "test \"s1: criterion 1\" do\nend\n")

    work = %{
      "kind" => "story",
      "id" => "s1",
      "root" => dir,
      "project" => "myproj",
      "criteria" => ["the user logs in"]
    }

    assert %{name: "work", actor: :coder, note: note} = Workflow.Run.step(work)
    assert note =~ "justfile does not contain recipe `run`"

    project_dir = Path.join(dir, "myproj")
    assert_received {:just, "run", _analysis_dir, ^project_dir}
  end

  # A journey at tree "t1" with one stage already named, for the owner's demo decision.
  defp journey(dir) do
    test_dir = Path.join([dir, "workflow", "test"])
    File.mkdir_p!(test_dir)
    File.write!(Path.join(test_dir, "journey_test.exs"), "test \"i1: stage 1\" do\nend\n")

    checkout(dir, 1, 0)
    |> Map.merge(%{"kind" => "journey", "root" => dir, "stages" => ["the user signs up"]})
  end

  test "a demo approved records it and moves the journey on to promote", %{tmp_dir: dir} do
    work = journey(dir)

    assert Workflow.Run.step(Map.merge(work, %{"review" => "pass", "demo" => "approve"})) == nil

    assert_received {"git", ["merge", "--no-ff", "--no-edit", "c1"]}
  end

  # A journey whose review passed, with `just` answered by `demo` where it answers (nil: as before).
  defp demo_journey(dir, demo) do
    work = journey(dir) |> Map.put("review", "pass")
    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn command, args, opts ->
      answer = stand_in.(command, args, opts)
      demo.(command, args) || answer
    end)

    work
  end

  test "journey-demo-can-be-seen: point 1 - after review, `just demo` runs into the demo folder beside the work's log, before the owner is asked",
       %{tmp_dir: dir} do
    work = demo_journey(dir, fn _command, _args -> nil end)

    assert %{name: "approve", actor: :owner} = Workflow.Run.step(work)

    demo_dir = Path.join([dir, "workflow", "analysis", "t1", "demo"])
    project_dir = Path.join(dir, "workflow")
    assert_received {:cwd, "just", ["demo", ^demo_dir], ^project_dir}
    assert %{"status" => "passed"} = Workflow.Run.look(work).found["demo"]
  end

  test "journey-demo-can-be-seen: point 2 - look's waiting note names every file the demo recipe left",
       %{tmp_dir: dir} do
    work =
      demo_journey(dir, fn
        "just", ["demo", demo_dir] ->
          File.write!(Path.join(demo_dir, "journey.webm"), "")
          File.mkdir_p!(Path.join(demo_dir, "shots"))
          File.write!(Path.join([demo_dir, "shots", "1.png"]), "")
          {"", 0}

        _command, _args ->
          nil
      end)

    Workflow.Run.step(work)

    demo_dir = Path.join([dir, "workflow", "analysis", "t1", "demo"])
    assert %{step: "approve", note: note} = Workflow.Run.look(work)
    assert note =~ "`#{Path.join(demo_dir, "journey.webm")}`"
    assert note =~ "`#{Path.join([demo_dir, "shots", "1.png"])}`"
  end

  test "journey-demo-can-be-seen: point 3 - a project with no demo recipe is no failure, and the note names the checkout and its branch",
       %{tmp_dir: dir} do
    work =
      demo_journey(dir, fn
        "just", ["--show", "demo"] -> {"error: Justfile does not contain recipe `demo`.", 1}
        _command, _args -> nil
      end)

    assert %{name: "approve", note: note} = Workflow.Run.step(work)
    refute_received {"just", ["demo" | _]}
    assert note =~ "no `demo` recipe"
    assert note =~ "`#{Path.join(dir, "workflow")}`"
    assert note =~ "branch `journey/i1`"
  end

  test "journey-demo-can-be-seen: point 4 - a failing demo recipe sends the work back to the coder with its output",
       %{tmp_dir: dir} do
    work =
      demo_journey(dir, fn
        "just", ["demo", _dir] -> {"the demo could not sign up", 1}
        _command, _args -> nil
      end)

    assert %{name: "work", actor: :coder, note: note} = Workflow.Run.step(work)
    assert note =~ "the demo could not sign up"
  end

  test "a demo rejected sends the journey back to the coder with the note", %{tmp_dir: dir} do
    work = journey(dir)

    assert %{name: "work", actor: :coder, note: "missed a step"} =
             Workflow.Run.step(
               Map.merge(work, %{
                 "review" => "pass",
                 "demo" => "reject",
                 "note" => "missed a step"
               })
             )
  end

  test "rejection-reaches-the-coder: criterion 1 - a rejection then a certify failure at the same tree gives the coder both",
       %{tmp_dir: dir} do
    work = journey(dir)
    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "git", ["merge", "--no-edit", _main], _opts -> {"CONFLICT in lib/a.ex", 1}
      command, args, opts -> stand_in.(command, args, opts)
    end)

    assert %{name: "work", actor: :coder, note: note} =
             Workflow.Run.step(
               Map.merge(work, %{
                 "review" => "pass",
                 "demo" => "reject",
                 "note" => "missed a step"
               })
             )

    assert note =~ "conflicts"
    assert note =~ "missed a step"
  end

  test "rejection-reaches-the-coder: criterion 2 - the rejection note outlives a tree move, until the coder has had a turn with it",
       %{tmp_dir: dir} do
    works_dir(dir)
    work = journey(dir)
    test = self()

    Workflow.Run.step(
      Map.merge(work, %{"review" => "pass", "demo" => "reject", "note" => "missed a step"})
    )

    # The coder merges the main branch: the tree moves.
    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "git", ["rev-parse", "HEAD^{tree}"], _opts -> {"t2\n", 0}
      command, args, opts -> stand_in.(command, args, opts)
    end)

    assert %{name: "work", actor: :coder, note: "missed a step"} = Workflow.Run.step(work)

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:ran, step.name, step.note})
      if step.name == "review", do: {%{"status" => "pass"}, nil}, else: {%{}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      Workflow.Run.start(Map.put(work, "agent", %{"provider" => "claude-code"}))
      settled()
    end)

    assert_received {:ran, "work", note}
    assert note =~ "missed a step"
    # Answered: the work goes on to review, and to the owner, without it.
    assert_received {:ran, "review", _note}
    refute_received {:ran, "work", _note}
    assert %{step: "approve"} = Workflow.Run.look(work)
  end

  test "rejection-reaches-the-coder: a rejection then a certify that merges the moved main branch cleanly, moving the tree, still reaches the coder before review, demo or approve",
       %{tmp_dir: dir} do
    works_dir(dir)
    work = journey(dir)
    {:ok, events} = Agent.start_link(fn -> %{tree: "t1", seen: []} end)
    seen = fn event -> Agent.update(events, &%{&1 | seen: &1.seen ++ [event]}) end
    stand_in = Application.get_env(:workflow, :cmd)

    # The main branch has moved: certify's merge succeeds and moves the tree to t2.
    Application.put_env(:workflow, :cmd, fn
      "git", ["rev-parse", "HEAD^{tree}"], _opts ->
        {Agent.get(events, & &1.tree) <> "\n", 0}

      "git", ["merge", "--no-edit", "trunk"], _opts ->
        Agent.update(events, &%{&1 | tree: "t2"})
        seen.(:merged)
        {"", 0}

      "just", ["demo" | _] = args, opts ->
        seen.(:demo)
        stand_in.("just", args, opts)

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      seen.({:ran, step.name, step.note})
      if step.name == "review", do: {%{"status" => "pass"}, nil}, else: {%{}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      Workflow.Run.start(
        Map.merge(work, %{
          "review" => "pass",
          "demo" => "reject",
          "note" => "missed a step",
          "agent" => %{"provider" => "claude-code"}
        })
      )

      settled()
    end)

    seen = Agent.get(events, & &1.seen)

    # Certify merged cleanly and moved the tree; the coder's turn, with the note, came next.
    assert [:merged, {:ran, "work", note} | after_work] = seen
    assert note =~ "missed a step"

    # Only after the coder answered: review, then demo, then the owner.
    assert [{:ran, "review", _review_note}, :demo] = after_work
    assert %{step: "approve", head: "t2"} = Workflow.Run.look(work)
  end

  # A journey approved at tree t1 whose tree then moves to t2, by certify's merge of
  # the moved main branch, with `since` the paths changed from t1 to t2 and `own`
  # the work's own changes against main.
  defp approved_then_moved(dir, since, own) do
    works_dir(dir)
    work = journey(dir)
    {:ok, tree} = Agent.start_link(fn -> "t1" end)
    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "git", ["rev-parse", "HEAD^{tree}"], _opts ->
        {Agent.get(tree, & &1) <> "\n", 0}

      "git", ["merge", "--no-edit", "trunk"], _opts ->
        Agent.update(tree, fn _t1 -> "t2" end)
        {"", 0}

      "git", ["diff", "--name-only", "t1", "HEAD"], _opts ->
        {since, 0}

      "git", ["diff", "--name-only", "trunk...HEAD"], _opts ->
        {own, 0}

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      if step.name == "review", do: {%{"status" => "pass"}, nil}, else: {%{}, nil}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    capture_log(fn ->
      Workflow.Run.start(
        Map.merge(work, %{
          "review" => "pass",
          "demo" => "approve",
          "agent" => %{"provider" => "claude-code"}
        })
      )

      settled()
    end)

    work
  end

  test "approval-survives-a-merge-of-main: criterion 1 - an approval still counts when the only change since is certify's merge of main, and the work goes on to promote",
       %{tmp_dir: dir} do
    work = approved_then_moved(dir, "lib/main_only.ex\n", "workflow/lib/journey.ex\n")

    assert %{head: "t2"} = Workflow.Run.look(work)
    assert_received {"git", ["merge", "--no-ff", "--no-edit", "c1"]}
  end

  test "approval-survives-a-merge-of-main: criterion 2 - a file of the work itself changed since the approval asks the owner again",
       %{tmp_dir: dir} do
    work =
      approved_then_moved(
        dir,
        "lib/main_only.ex\nworkflow/lib/journey.ex\n",
        "workflow/lib/journey.ex\n"
      )

    refute_received {"git", ["merge", "--no-ff", "--no-edit", "c1"]}
    assert %{step: "approve", head: "t2"} = Workflow.Run.look(work)
  end

  test "own-checkout: stage 1 - a work with repo and no root gets a worktree checkout beside it, and runs with it as root",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    checkout_dir = Path.join(dir, "myrepo-i1")
    work = checkout(dir, 0, 0, repo: repo)

    assert %{name: "fix", actor: :coder} = Workflow.Run.step(work)

    assert_received {"git", ["worktree", "add" | add_args]}
    assert checkout_dir in add_args
    assert "issue/i1" in add_args

    assert_received {:cwd, "git", ["rev-parse", "HEAD^{tree}"], ^checkout_dir}
  end

  test "own-checkout: stage 2 - a work handed in again with the same repo and id uses the checkout already there, and makes no second one",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    checkout_dir = Path.join(dir, "myrepo-i1")
    work = checkout(dir, 0, 0, repo: repo)

    assert %{name: "fix", actor: :coder} = Workflow.Run.step(work)
    assert_received {"git", ["worktree", "add" | _]}
    assert_received {:cwd, "git", ["rev-parse", "HEAD^{tree}"], ^checkout_dir}

    assert %{name: "fix", actor: :coder} = Workflow.Run.step(work)
    refute_received {"git", ["worktree", "add" | _]}
    assert_received {:cwd, "git", ["rev-parse", "HEAD^{tree}"], ^checkout_dir}
  end

  # Every command the stand-in was asked to run since last asked, as {command, args}, oldest first.
  defp commands do
    receive do
      {:cwd, _command, _args, _cd} -> commands()
      {command, args} when is_binary(command) -> [{command, args} | commands()]
    after
      0 -> []
    end
  end

  # The checkout's stand-in, with `just copy-setup` and `just copy-teardown` answering as
  # given, and a copy cut with the work's project directory in it.
  defp recipes(setup, teardown) do
    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "git", ["worktree", "add", "-b", _branch, path | _at] = args, opts ->
        File.mkdir_p!(Path.join(path, "workflow"))
        stand_in.("git", args, opts)

      "just", ["copy-setup"] = args, opts ->
        stand_in.("just", args, opts)
        setup

      "just", ["copy-teardown"] = args, opts ->
        stand_in.("just", args, opts)
        teardown

      command, args, opts ->
        stand_in.(command, args, opts)
    end)
  end

  test "copy-lifecycle-recipes: criterion 1 - a copy the loop makes is set up by `just copy-setup` in the work's project, once, after `git worktree add`, and not when it is reused",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    project_dir = Path.join([dir, "myrepo-i1", "workflow"])
    work = checkout(dir, 0, 0, repo: repo)
    recipes({"", 0}, {"", 0})

    assert %{name: "fix", actor: :coder} = Workflow.Run.step(work)
    assert_received {:cwd, "just", ["copy-setup"], ^project_dir}
    ran = commands()
    added = Enum.find_index(ran, &match?({"git", ["worktree", "add" | _]}, &1))
    assert added < Enum.find_index(ran, &(&1 == {"just", ["copy-setup"]}))
    refute {"mix", ["deps.get"]} in ran

    assert %{name: "fix", actor: :coder} = Workflow.Run.step(work)
    ran = commands()
    refute {"just", ["copy-setup"]} in ran
    refute Enum.any?(ran, &match?({"git", ["worktree", "add" | _]}, &1))
  end

  test "copy-lifecycle-recipes: criterion 2 - a work done runs `just copy-teardown` in its copy before the worktree is removed",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    checkout_dir = Path.join(dir, "myrepo-i1")
    project_dir = Path.join(checkout_dir, "workflow")
    work = checkout(dir, 1, 0, repo: repo)
    recipes({"", 0}, {"", 0})

    assert Workflow.Run.step(Map.put(work, "review", "pass")) == nil
    assert_received {:cwd, "just", ["copy-teardown"], ^project_dir}
    ran = commands()
    # The copy's own removal, not the ci checkout's.
    removed = Enum.find_index(ran, &(&1 == {"git", ["worktree", "remove", checkout_dir]}))
    assert Enum.find_index(ran, &(&1 == {"just", ["copy-teardown"]})) < removed
  end

  test "copy-lifecycle-recipes: criterion 2 - a work cancelled runs `just copy-teardown` in its copy before the worktree is removed",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    project_dir = Path.join([dir, "myrepo-i1", "workflow"])
    work = checkout(dir, 0, 0, repo: repo)
    recipes({"", 0}, {"", 0})

    assert %{name: "fix"} = Workflow.Run.step(work)
    commands()

    Workflow.Run.cancel(work)
    assert_received {:cwd, "just", ["copy-teardown"], ^project_dir}
    ran = commands()

    removed =
      Enum.find_index(ran, &match?({"git", ["worktree", "remove", "--force" | _]}, &1))

    assert Enum.find_index(ran, &(&1 == {"just", ["copy-teardown"]})) < removed
    assert {"git", ["branch", "-D", "issue/i1"]} in ran
  end

  test "stop-ends-the-turn-first: criteria 1 and 2 - a work stopped mid-turn has its turn ended before its worktree and branch go, and nothing crashes",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    checkout_dir = Path.join(dir, "myrepo-i1")
    works_dir(dir)
    # The main copy is where a stop is marked, and read again.
    File.mkdir_p!(repo)
    work = checkout(dir, 0, 0, repo: repo) |> Map.put("agent", %{"provider" => "claude-code"})
    recipes({"", 0}, {"", 0})
    test = self()
    {:ok, seen} = Agent.start_link(fn -> %{turn: nil, removed: false} end)
    stand_in = Application.get_env(:workflow, :cmd)

    # What is removed says whether the turn was still running; a checkout gone is no git checkout.
    Application.put_env(:workflow, :cmd, fn
      "git", ["worktree", "remove" | _] = args, opts ->
        turn = Agent.get(seen, & &1.turn)
        send(test, {:removed, args, Process.alive?(turn)})
        Agent.update(seen, &%{&1 | removed: true})
        stand_in.("git", args, opts)

      "git", ["branch", "-D" | _] = args, opts ->
        send(test, {:branch_deleted, Process.alive?(Agent.get(seen, & &1.turn))})
        stand_in.("git", args, opts)

      "git", ["rev-parse", "--path-format=absolute", "--git-common-dir"] = args, opts ->
        if opts[:cd] == checkout_dir and Agent.get(seen, & &1.removed),
          do: {"fatal: not a git repository\n", 128},
          else: stand_in.("git", args, opts)

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    # A stand-in agent whose turn runs until it is told to end.
    Application.put_env(:workflow, :agents_run, fn _step, _work ->
      turn = self()
      Agent.update(seen, &%{&1 | turn: turn})
      send(test, {:turn, turn})

      receive do
        :finish -> {%{}, nil}
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    log =
      capture_log(fn ->
        assert {%{name: "copy-setup"}, "started"} = Workflow.Run.start(work)
        assert_receive {:turn, turn}, 5_000
        ref = Process.monitor(turn)

        Workflow.Run.cancel(work)

        # A turn left running would end now, in a checkout that is gone.
        send(turn, :finish)
        assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
        settled()
        Process.sleep(50)
      end)

    assert_received {:removed, ["worktree", "remove", "--force", ^checkout_dir], false}
    assert_received {:branch_deleted, false}
    refute log =~ "MatchError"
    refute log =~ "[error]"
    refute log =~ "went down"
    assert Workflow.Run.step(work) == :cancelled
  end

  test "stop-ends-the-turn-first: criterion 3 - a work stopped with no turn running has its checkout, branch and file removed and never promotes",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    checkout_dir = Path.join(dir, "myrepo-i1")
    works = works_dir(dir)
    File.mkdir_p!(repo)
    work = checkout(dir, 1, 0, repo: repo)
    recipes({"", 0}, {"", 0})

    assert %{name: "review"} = Workflow.Run.step(work)
    file = in_flight(works, work)
    commands()

    Workflow.Run.cancel(work)
    ran = commands()
    assert {"just", ["copy-teardown"]} in ran
    assert {"git", ["worktree", "remove", "--force", checkout_dir]} in ran
    assert {"git", ["branch", "-D", "issue/i1"]} in ran
    refute File.exists?(file)

    assert Workflow.Run.step(Map.put(work, "review", "pass")) == :cancelled
    refute Enum.any?(commands(), &match?({"git", ["push" | _]}, &1))
  end

  test "copy-lifecycle-recipes: criterion 2 - a copy-teardown that fails is logged, and the worktree and branch are removed all the same",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    checkout_dir = Path.join(dir, "myrepo-i1")
    work = checkout(dir, 1, 0, repo: repo)
    recipes({"", 0}, {"teardown broke", 1})

    log =
      capture_log(fn ->
        assert Workflow.Run.step(Map.put(work, "review", "pass")) == nil
      end)

    assert log =~ "copy-teardown" and log =~ "teardown broke"
    assert_received {"git", ["worktree", "remove", ^checkout_dir]}
    assert_received {"git", ["branch", "-D", "issue/i1"]}
  end

  test "copy-lifecycle-recipes: criterion 3 - a project with no copy-setup recipe stops the work, its reason the recipe's output, and leaves no copy",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    checkout_dir = Path.join(dir, "myrepo-i1")
    works = works_dir(dir)
    work = checkout(dir, 0, 0, repo: repo)
    recipes({"error: Justfile does not contain recipe `copy-setup`.\n", 1}, {"", 0})

    capture_log(fn ->
      assert {%{name: "copy-setup"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert %{"step" => "copy-setup", "reason" => reason} = Workflow.Run.stopped(work)
    assert reason =~ "this project has no copy-setup recipe"
    assert reason =~ "does not contain recipe `copy-setup`"
    assert Path.wildcard(Path.join(works, "*.json")) == []
    assert_received {"git", ["worktree", "remove", "--force", ^checkout_dir]}
    refute_received {:agent, _step, _work}
  end

  test "copy-lifecycle-recipes: criterion 3 - a copy-setup that fails stops the work with its output",
       %{tmp_dir: dir} do
    works = works_dir(dir)
    manager()
    work = checkout(dir, 0, 0, repo: Path.join(dir, "myrepo"))
    recipes({"could not fetch deps\n", 2}, {"", 0})

    capture_log(fn ->
      assert {%{name: "copy-setup"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert %{"step" => "copy-setup", "reason" => why} = Workflow.Run.stopped(work)
    assert why =~ "could not fetch deps"
    assert why =~ "exit 2"
    assert Path.wildcard(Path.join(works, "*.json")) == []

    # Said to the manager as any step's stop is, never a silent half-started work.
    assert_receive {:manager_told, notice}, 2_000
    assert notice =~ "issue i1: stopped at copy-setup"
    assert notice =~ "could not fetch deps"
  end

  test "own-checkout: stage 4 - a finished work has its checkout removed and its branch deleted; an unfinished one keeps its checkout",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    checkout_dir = Path.join(dir, "myrepo-i1")

    unfinished = checkout(dir, 0, 0, repo: repo)
    assert %{name: "fix", actor: :coder} = Workflow.Run.step(unfinished)
    refute_received {"git", ["worktree", "remove" | _]}
    refute_received {"git", ["branch", "-D" | _]}

    finished = checkout(dir, 1, 0, repo: repo)
    assert Workflow.Run.step(Map.put(finished, "review", "pass")) == nil

    assert_received {"git", ["worktree", "remove", ^checkout_dir]}
    assert_received {"git", ["branch", "-D", "issue/i1"]}
  end

  test "own-checkout: a work that names both root and repo keeps its checkout when finished, since the loop did not make it",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    work = checkout(dir, 1, 0) |> Map.put("repo", repo)

    assert Workflow.Run.step(Map.put(work, "review", "pass")) == nil

    owned = repo <> "-i1"
    refute_received {"git", ["worktree", "remove", ^owned | _]}
    refute_received {"git", ["branch", "-D" | _]}
  end

  test "own-checkout: start resolves a repo into a root once, so an agent's provider is looked up in the checkout just cut, not the un-owned work",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "myrepo")
    checkout_dir = Path.join(dir, "myrepo-i1")

    work =
      checkout(dir, 0, 0, repo: repo)
      |> Map.put("agent", %{"provider" => "not-a-real-provider"})

    # Agents.provider/2 requires "root": called with the original repo-only work
    # (no "root" added yet) this would raise, not return a tidy "not started".
    works_dir(dir)

    capture_log(fn ->
      assert {%{name: "copy-setup"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert %{"step" => "fix", "reason" => note} = Workflow.Run.stopped(work)
    assert note =~ "not started"

    assert_received {"git", ["worktree", "add" | add_args]}
    assert checkout_dir in add_args
    refute_received {"git", ["worktree", "add" | _]}
  end

  test "messages: criterion 5 - the loop's notice to the manager when a work is done is kept in the manager's inbox and delivered through the same path",
       %{tmp_dir: dir} do
    test = self()
    works = works_dir(dir)
    work = checkout(dir, 1, 0) |> Map.put("agent", %{"provider" => "claude-code"})

    was =
      for key <- [:manager, :manager_run, :recipients],
          do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end

      Application.delete_env(:workflow, :agents_run)
    end)

    Application.delete_env(:workflow, :recipients)

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      send(test, {:manager_told, message})
      {:ok, %{text: "noted", messages: opts[:messages]}}
    end)

    Application.put_env(:workflow, :agents_run, fn _step, _work ->
      {%{"status" => "pass"}, nil}
    end)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    # Delivered: the manager's next turn is the notice.
    assert_receive {:manager_told, notice}, 2_000
    assert notice =~ "issue i1"
    assert notice =~ "done"

    # Kept: one line in the manager's inbox beside the works directory.
    inbox = Path.join([Path.dirname(works), "inbox", "manager.jsonl"])
    assert File.regular?(inbox)

    assert [line] = inbox |> File.read!() |> String.split("\n", trim: true)
    assert %{"to" => "manager", "from" => "workflow", "text" => ^notice} = Jason.decode!(line)
  end

  test "manager-sees-outcome: criterion 1 - the done message carries the last decision note and the landed commit with its shortstat line, or that nothing landed",
       %{tmp_dir: dir} do
    works_dir(dir)
    manager()
    on_exit(fn -> Application.delete_env(:workflow, :agents_run) end)

    Application.put_env(:workflow, :agents_run, fn _step, _work ->
      {%{"status" => "pass", "note" => "the test covers the fault"}, nil}
    end)

    # A work that lands: reviewed, promoted as commit c1.
    work = checkout(dir, 1, 0) |> Map.put("agent", %{"provider" => "claude-code"})

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      settled()
    end)

    assert_receive {:manager_told, notice}, 2_000
    assert notice =~ "issue i1: done"
    assert notice =~ "Last decision note: the test covers the fault"
    assert notice =~ "Landed as commit c1: 2 files changed, 3 insertions(+), 1 deletion(-)"
    assert_received {"git", ["diff", "--shortstat", "c1^1", "c1"]}

    # A work that lands nothing: a provision with no commits of its own.
    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "steps"]), "a\n")
    empty = checkout(dir, 0, 0) |> Map.merge(%{"kind" => "provision", "id" => "p1"})

    capture_log(fn ->
      Workflow.Run.start(empty)
      settled()
    end)

    assert_receive {:manager_told, notice}, 2_000
    assert notice =~ "provision p1: done"
    assert notice =~ "Nothing landed."
    refute notice =~ "Landed as commit"
  end
end
