defmodule Workflow.ReleaseRecipeTest do
  use ExUnit.Case, async: true

  # Never give `just release` inputs that pass its checks: it publishes.
  setup do
    root = Path.join(System.tmp_dir!(), "release-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    bin = Path.join(root, "bin")
    log = Path.join(root, "calls.log")
    File.mkdir_p!(repo)
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)

    git = System.find_executable("git")
    {_, 0} = System.cmd(git, ["init", "-q", repo])

    {_, 0} =
      System.cmd(git, [
        "-C",
        repo,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.com",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "one"
      ])

    # Fakes that record any call: gh and mix (a package build) never run for real;
    # git records a clone or push and refuses it, and passes anything else through.
    for name <- ["gh", "mix"] do
      fake(bin, name, "echo \"#{name} $*\" >> '#{log}'\nexit 1\n")
    end

    fake(bin, "git", """
    for a in "$@"; do case "$a" in clone|push) echo "git $*" >> '#{log}'; exit 1;; esac; done
    exec '#{git}' "$@"
    """)

    %{root: root, repo: repo, bin: bin, log: log, git: git}
  end

  defp fake(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp release(%{repo: repo, bin: bin, root: root}, version) do
    System.cmd(
      "just",
      [
        "--justfile",
        Path.join(File.cwd!(), "justfile"),
        "--working-directory",
        repo,
        "release",
        version,
        root
      ],
      stderr_to_stdout: true,
      env: [{"PATH", bin <> ":" <> System.get_env("PATH")}]
    )
  end

  defp refute_published(%{log: log, root: root}) do
    case File.read(log) do
      {:ok, calls} -> flunk("calls made: #{calls}")
      {:error, :enoent} -> :ok
    end

    refute File.exists?(Path.join([root, "repo", "_build"]))
  end

  test "release-recipe: criterion 1 a version that is not N.N.N is refused, naming it, before anything is published",
       ctx do
    for version <- ["3.0", "v3.0.4", "3.0.4-rc1"] do
      {said, status} = release(ctx, version)
      assert status != 0, said
      assert said =~ "version #{version} is not N.N.N", said
      refute_published(ctx)
    end
  end

  test "release-recipe: criterion 2 a HEAD not tagged v<version> is refused, saying so, before anything is published",
       %{repo: repo, git: git} = ctx do
    {said, status} = release(ctx, "3.0.4")
    assert status != 0, said
    assert said =~ "HEAD is not tagged v3.0.4", said
    refute_published(ctx)

    {_, 0} = System.cmd(git, ["-C", repo, "tag", "v3.0.3"])
    {said, status} = release(ctx, "3.0.4")
    assert status != 0, said
    assert said =~ "HEAD is not tagged v3.0.4", said
    refute_published(ctx)
  end

  test "release-recipe: criterion 3 the formula is a template the release recipe fills in" do
    formula = File.read!(Path.join(File.cwd!(), "packaging/codemyspec.rb"))
    assert formula =~ ~s(version "__VERSION__")
    assert formula =~ ~s(url "__URL__")
    assert formula =~ ~s(sha256 "__SHA256__")

    justfile = File.read!(Path.join(File.cwd!(), "justfile"))
    assert justfile =~ "s|__VERSION__|"
    assert justfile =~ "s|__URL__|"
    assert justfile =~ "s|__SHA256__|"
    assert justfile =~ "packaging/codemyspec.rb"
  end

  test "release-recipe: criterion 4 packaging/README.md's build steps are the one just release command" do
    readme = File.read!(Path.join(File.cwd!(), "packaging/README.md"))
    [_, build] = Regex.run(~r/^## Build[^\n]*\n(.*?)(?=^## )/ms, readme)
    assert build =~ ~r/^\s+just release <version> <app>$/m
    refute build =~ ~r/^\d+\. /m
    refute build =~ "Upload"
    refute build =~ "Hand `packaging/codemyspec.rb` off"
    refute build =~ ~r/^\s+just package /m
  end

  # Every outside call is a fake: gh records and succeeds, mix lays out a release,
  # git clone makes a local tap (with or without the old formula) and git push
  # records the tap's commit instead of pushing it.
  defp fake_publish(%{bin: bin, log: log, git: git, root: root, repo: repo}, old_formula?) do
    fake(bin, "gh", """
    echo "gh $*" >> '#{log}'
    [ "$1 $2" = "release view" ] && exit 1
    exit 0
    """)

    fake(bin, "mix", """
    case " $* " in *" release "*) mkdir -p _build/prod/rel/workflow/bin && echo w > _build/prod/rel/workflow/bin/workflow;; esac
    exit 0
    """)

    old = if old_formula?, do: "yes", else: ""

    fake(bin, "git", """
    if [ "$1" = clone ]; then
      for dest; do :; done
      '#{git}' init -q "$dest"
      '#{git}' -C "$dest" config user.name t
      '#{git}' -C "$dest" config user.email t@example.com
      echo tap > "$dest/README.md"
      if [ -n "#{old}" ]; then mkdir -p "$dest/Formula"; echo old > "$dest/Formula/codemyspec-loop.rb"; fi
      '#{git}' -C "$dest" add -A
      '#{git}' -C "$dest" commit -q -m init
      exit 0
    fi
    if [ "$3" = push ]; then
      '#{git}' -C "$2" show --name-status --format='commit: %s' HEAD >> '#{log}'
      '#{git}' -C "$2" show HEAD:Formula/codemyspec.rb >> '#{log}'
      exit 0
    fi
    exec '#{git}' "$@"
    """)

    app = Path.join(root, "app")
    File.mkdir_p!(Path.join(app, "plugins/phoenix/.claude-plugin"))
    File.write!(Path.join(app, "plugins/phoenix/.claude-plugin/plugin.json"), ~s({"name": "p"}))
    File.mkdir_p!(Path.join(app, "plugins/claude/directory/skills/interview"))
    File.write!(Path.join(app, "plugins/claude/directory/skills/interview/SKILL.md"), "brief\n")

    {_, 0} = System.cmd(git, ["-C", repo, "tag", "v3.0.4"])

    System.cmd(
      "just",
      ["--justfile", Path.join(File.cwd!(), "justfile"), "--working-directory", repo] ++
        ["release", "3.0.4", app],
      stderr_to_stdout: true,
      env: [{"PATH", bin <> ":" <> System.get_env("PATH")}]
    )
  end

  test "the-loop-publishes-as-codemyspec: release writes Formula/codemyspec.rb and removes Formula/codemyspec-loop.rb in one commit",
       %{log: log} = ctx do
    {said, status} = fake_publish(ctx, true)
    assert status == 0, said
    calls = File.read!(log)

    url = "https://github.com/Code-My-Spec/workflow/releases/download/v3.0.4/codemyspec-darwin-arm64.tar.gz"
    assert calls =~ ~r/^gh release create v3\.0\.4 .+\/_build\/codemyspec-darwin-arm64\.tar\.gz /m, calls
    assert calls =~ "--notes codemyspec 3.0.4 for macOS", calls
    assert calls =~ "commit: codemyspec 3.0.4\n", calls
    assert calls =~ ~r/^A\tFormula\/codemyspec\.rb$/m, calls
    assert calls =~ ~r/^D\tFormula\/codemyspec-loop\.rb$/m, calls
    assert calls =~ "class Codemyspec < Formula", calls
    assert calls =~ ~s(url "#{url}"), calls
    assert calls =~ ~s(version "3.0.4"), calls
  end

  test "the-loop-publishes-as-codemyspec: release into a tap without Formula/codemyspec-loop.rb still commits Formula/codemyspec.rb",
       %{log: log} = ctx do
    {said, status} = fake_publish(ctx, false)
    assert status == 0, said
    calls = File.read!(log)

    assert calls =~ "commit: codemyspec 3.0.4\n", calls
    assert calls =~ ~r/^A\tFormula\/codemyspec\.rb$/m, calls
    refute calls =~ "codemyspec-loop", calls
  end
end
