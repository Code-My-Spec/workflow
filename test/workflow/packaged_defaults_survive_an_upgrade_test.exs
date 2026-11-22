defmodule Workflow.PackagedDefaultsSurviveAnUpgradeTest do
  use ExUnit.Case, async: false

  @keys [:works_dir, :plugin, :instructions]

  # Each test has its own works directory and release root, never the real ~/.workflow.
  setup do
    root = Path.join(System.tmp_dir!(), "upgrade-#{System.unique_integer([:positive])}")
    works = Path.join([root, "home", "works"])
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", repo])

    before = for key <- @keys, do: {key, Application.fetch_env(:workflow, key)}
    release_root = System.get_env("RELEASE_ROOT")
    Application.put_env(:workflow, :works_dir, works)
    Application.delete_env(:workflow, :plugin)
    Application.delete_env(:workflow, :instructions)

    on_exit(fn ->
      for {key, saved} <- before do
        case saved do
          {:ok, value} -> Application.put_env(:workflow, key, value)
          :error -> Application.delete_env(:workflow, key)
        end
      end

      if release_root,
        do: System.put_env("RELEASE_ROOT", release_root),
        else: System.delete_env("RELEASE_ROOT")

      File.rm_rf!(root)
    end)

    config = Path.join([root, "home", "config.json"])
    File.mkdir_p!(Path.dirname(config))
    %{root: root, repo: repo, config: config}
  end

  defp plugin(dir) do
    File.mkdir_p!(Path.join(dir, ".claude-plugin"))
    File.write!(Path.join([dir, ".claude-plugin", "plugin.json"]), ~s({"name": "p"}))
    dir
  end

  # An unpacked release, as `just package` lays it out, named by RELEASE_ROOT.
  defp release(root, name \\ "rel") do
    rel = Path.join(root, name)
    plugin(Path.join(rel, "plugin"))
    File.write!(Path.join(rel, "instructions.md"), "---\nname: interview\n---\nbrief\n")
    System.put_env("RELEASE_ROOT", rel)
    rel
  end

  test "packaged-defaults-survive-an-upgrade: criterion 1 init with no --plugin writes neither plugin nor instructions",
       %{root: root, repo: repo, config: config} do
    release(root)

    assert {:ok, _said} = Workflow.Init.run(["--repo", repo], root)
    written = config |> File.read!() |> Jason.decode!()

    refute Map.has_key?(written, "plugin")
    refute Map.has_key?(written, "instructions")
  end

  test "packaged-defaults-survive-an-upgrade: criterion 1 init with --plugin DIR still writes that DIR",
       %{root: root, repo: repo, config: config} do
    release(root)
    mine = plugin(Path.join(root, "mine"))

    assert {:ok, _said} = Workflow.Init.run(["--repo", repo, "--plugin", mine], root)
    written = config |> File.read!() |> Jason.decode!()

    assert written["plugin"] == mine
    refute Map.has_key?(written, "instructions")
  end

  test "packaged-defaults-survive-an-upgrade: criterion 2 a config with no plugin or instructions uses the release's packaged ones at boot",
       %{root: root, config: config} do
    rel = release(root)
    File.write!(config, "{}")

    assert :ok = Workflow.ConfigFile.load()
    assert Application.get_env(:workflow, :plugin) == Path.join(rel, "plugin")
    assert Application.get_env(:workflow, :instructions) == "brief\n"
  end

  test "packaged-defaults-survive-an-upgrade: criterion 3 a config naming a missing plugin or instructions fails at start naming it",
       %{root: root, config: config} do
    release(root)

    for {key, gone} <- [
          {"plugin", Path.join(root, "gone-plugin")},
          {"instructions", Path.join(root, "gone-instructions.md")}
        ] do
      Application.delete_env(:workflow, :plugin)
      File.write!(config, Jason.encode!(%{key => gone}))

      assert {:error, why} = Workflow.ConfigFile.load()
      assert why =~ gone
    end

    # A missing plugin is never run past: the boot stops with none set.
    assert Application.get_env(:workflow, :instructions) == nil
  end

  # The decision: a 3.0.1 config naming an older Cellar folder is not rewritten or
  # quietly swapped for the installed version's; the start fails naming the old
  # path, and README says to delete the two keys.
  test "packaged-defaults-survive-an-upgrade: a 3.0.1 config naming an older version's Cellar paths fails at start naming them",
       %{root: root, config: config} do
    old = release(root, "Cellar/codemyspec-loop/3.0.1/libexec")
    old_plugin = Path.join(old, "plugin")
    old_brief = Path.join(old, "instructions.md")
    release(root, "Cellar/codemyspec-loop/3.0.2/libexec")
    File.rm_rf!(old)

    body = Jason.encode!(%{"plugin" => old_plugin, "instructions" => old_brief})
    File.write!(config, body)

    assert {:error, why} = Workflow.ConfigFile.load()
    assert why =~ old_plugin
    assert Application.get_env(:workflow, :plugin) == nil
    assert File.read!(config) == body

    File.write!(config, Jason.encode!(%{"instructions" => old_brief}))
    Application.delete_env(:workflow, :plugin)
    assert {:error, why} = Workflow.ConfigFile.load()
    assert why =~ old_brief
  end

  test "packaged-defaults-survive-an-upgrade: criterion 4 README's install section says init leaves the packaged plugin and instructions out of config.json" do
    [install | _] =
      Path.join(File.cwd!(), "README.md")
      |> File.read!()
      |> String.split(~r/^## /m)
      |> Enum.drop(1)

    assert install =~ ~r/^Install\n/
    text = String.replace(install, ~r/\s+/, " ")
    assert text =~ "Init leaves the packaged plugin and chat instructions out of config.json"
    assert text =~ "follow the installed version across upgrades"
  end
end
