defmodule Workflow.PackageCarriesThePluginTest do
  use ExUnit.Case, async: false

  @tarball "codemyspec-darwin-arm64.tar.gz"
  @plugin "plugins/phoenix"
  @instructions "plugins/claude/directory/skills/interview/SKILL.md"

  # Each test has its own works directory and release root, never the real ~/.workflow.
  setup do
    root = Path.join(System.tmp_dir!(), "package-#{System.unique_integer([:positive])}")
    works = Path.join([root, "home", "works"])
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", repo])

    before = Application.get_env(:workflow, :works_dir)
    release_root = System.get_env("RELEASE_ROOT")
    Application.put_env(:workflow, :works_dir, works)

    on_exit(fn ->
      Application.put_env(:workflow, :works_dir, before)

      if release_root,
        do: System.put_env("RELEASE_ROOT", release_root),
        else: System.delete_env("RELEASE_ROOT")

      File.rm_rf!(root)
    end)

    %{root: root, repo: repo, config: Path.join([root, "home", "config.json"])}
  end

  defp plugin(dir) do
    File.mkdir_p!(Path.join(dir, ".claude-plugin"))
    File.write!(Path.join([dir, ".claude-plugin", "plugin.json"]), ~s({"name": "p"}))
    dir
  end

  # An unpacked release, as `just package` lays it out: its plugin and instructions at its root.
  defp release(root) do
    rel = Path.join(root, "rel")
    plugin(Path.join(rel, "plugin"))
    File.write!(Path.join(rel, "instructions.md"), "---\nname: interview\n---\nbrief\n")
    System.put_env("RELEASE_ROOT", rel)
    rel
  end

  # Since packaged-defaults-survive-an-upgrade, init leaves the packaged ones out of
  # config.json and the loop finds them in the release at each boot.
  test "package-carries-the-plugin: criterion 3 init with no --plugin leaves the packaged plugin and instructions to the release",
       %{root: root, repo: repo, config: config} do
    release(root)

    assert {:ok, said} = Workflow.Init.run(["--repo", repo], root)
    written = config |> File.read!() |> Jason.decode!()

    refute Map.has_key?(written, "plugin")
    refute Map.has_key?(written, "instructions")
    assert said =~ "brew services start codemyspec"
  end

  test "package-carries-the-plugin: criterion 4 an explicit --plugin still wins over the packaged one",
       %{root: root, repo: repo, config: config} do
    release(root)
    mine = plugin(Path.join(root, "mine"))

    assert {:ok, _said} = Workflow.Init.run(["--repo", repo, "--plugin", mine], root)
    written = config |> File.read!() |> Jason.decode!()

    assert written["plugin"] == mine
    refute Map.has_key?(written, "instructions")
  end

  test "package-carries-the-plugin: criterion 4 README's install section runs init with only --repo" do
    [install | _] =
      Path.join(File.cwd!(), "README.md")
      |> File.read!()
      |> String.split(~r/^## /m)
      |> Enum.drop(1)

    assert install =~ ~r/^Install\n/
    assert install =~ ~r/^\s+workflow init --repo \S+\s*(#.*)?$/m
    refute install =~ "[--plugin"

    assert File.read!(Path.join(File.cwd!(), "packaging/README.md")) =~ "just package "
  end

  test "package-carries-the-plugin: criterion 2 just package with no path, a missing path, or a missing source fails naming it and builds no tarball",
       %{root: root} do
    only_plugin = Path.join(root, "only-plugin")
    plugin(Path.join(only_plugin, @plugin))

    only_instructions = Path.join(root, "only-instructions")
    File.mkdir_p!(Path.dirname(Path.join(only_instructions, @instructions)))
    File.write!(Path.join(only_instructions, @instructions), "brief\n")

    gone = Path.join(root, "no such repo")
    work = Path.join(root, "work")
    File.mkdir_p!(work)

    for {args, named} <- [
          {[], "path"},
          {[gone], gone},
          {[only_instructions], @plugin},
          {[only_plugin], @instructions}
        ] do
      {said, status} =
        System.cmd(
          "just",
          [
            "--justfile",
            Path.join(File.cwd!(), "justfile"),
            "--working-directory",
            work,
            "package"
          ] ++
            args,
          stderr_to_stdout: true
        )

      assert status != 0, "#{inspect(args)} passed: #{said}"
      assert said =~ named, "#{inspect(args)} gave #{said}"
      refute File.exists?(Path.join([work, "_build", @tarball]))
      refute File.exists?(Path.join(work, "_build"))
    end
  end

  test "package-carries-the-plugin: criterion 1 just package copies the plugin and instructions into the release before the tarball" do
    package =
      Path.join(File.cwd!(), "justfile")
      |> File.read!()
      |> String.split("package ", parts: 2)
      |> List.last()

    copy_plugin = :binary.match(package, "/#{@plugin}\" _build/prod/rel/workflow/plugin")

    copy_brief =
      :binary.match(package, "/#{@instructions}\" _build/prod/rel/workflow/instructions.md")

    tar = :binary.match(package, "tar -C _build/prod/rel/workflow")

    assert copy_plugin != :nomatch and copy_brief != :nomatch and tar != :nomatch
    assert copy_plugin < tar and copy_brief < tar
  end

  test "package-carries-the-plugin: just package scans what it would ship and stops on a personal path, an email or a key, naming file and line, building no tarball",
       %{root: root} do
    app = Path.join(root, "app")
    plugin(Path.join(app, @plugin))
    skill = Path.join([app, @plugin, "skills", "coder", "SKILL.md"])
    File.mkdir_p!(Path.dirname(skill))

    File.write!(
      skill,
      "write to user@example.com\nrun /Users/someone/bin/x\nmail a.person@company.io\nfrom onboarding@resend.dev\nsend as notifications@mail.example.com\n"
    )

    File.mkdir_p!(Path.dirname(Path.join(app, @instructions)))
    File.write!(Path.join(app, @instructions), "key AKIAABCDEFGHIJKLMNOP\n")
    work = Path.join(root, "work")
    File.mkdir_p!(work)

    {said, status} =
      System.cmd(
        "just",
        [
          "--justfile",
          Path.join(File.cwd!(), "justfile"),
          "--working-directory",
          work,
          "package",
          app
        ],
        stderr_to_stdout: true
      )

    assert status != 0, said
    assert said =~ "skills/coder/SKILL.md:2:/Users/someone/bin/x", said
    assert said =~ "skills/coder/SKILL.md:3:a.person@company.io", said
    assert said =~ "#{@instructions}:1:AKIAABCDEFGHIJKLMNOP", said
    refute said =~ "user@example.com"
    refute said =~ "onboarding@resend.dev"
    refute said =~ "notifications@mail.example.com"
    refute File.exists?(Path.join(work, "_build"))
  end
end
