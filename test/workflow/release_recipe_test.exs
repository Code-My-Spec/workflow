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
    formula = File.read!(Path.join(File.cwd!(), "packaging/codemyspec-loop.rb"))
    assert formula =~ ~s(version "__VERSION__")
    assert formula =~ ~s(url "__URL__")
    assert formula =~ ~s(sha256 "__SHA256__")

    justfile = File.read!(Path.join(File.cwd!(), "justfile"))
    assert justfile =~ "s|__VERSION__|"
    assert justfile =~ "s|__URL__|"
    assert justfile =~ "s|__SHA256__|"
    assert justfile =~ "packaging/codemyspec-loop.rb"
  end

  test "release-recipe: criterion 4 packaging/README.md's build steps are the one just release command" do
    readme = File.read!(Path.join(File.cwd!(), "packaging/README.md"))
    [_, build] = Regex.run(~r/^## Build[^\n]*\n(.*?)(?=^## )/ms, readme)
    assert build =~ ~r/^\s+just release <version> <app>$/m
    refute build =~ ~r/^\d+\. /m
    refute build =~ "Upload"
    refute build =~ "Hand `packaging/codemyspec-loop.rb` off"
    refute build =~ ~r/^\s+just package /m
  end
end
