defmodule Workflow.InitTest do
  use ExUnit.Case, async: false

  # Each test has its own works directory, so config.json is never the real ~/.workflow one.
  setup do
    root = Path.join(System.tmp_dir!(), "init-#{System.unique_integer([:positive])}")
    works = Path.join([root, "home", "works"])
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", repo])

    before = Application.get_env(:workflow, :works_dir)
    Application.put_env(:workflow, :works_dir, works)

    on_exit(fn ->
      Application.put_env(:workflow, :works_dir, before)
      File.rm_rf!(root)
    end)

    %{root: root, repo: repo, config: Path.join([root, "home", "config.json"])}
  end

  defp plugin(root) do
    dir = Path.join(root, "plugin")
    File.mkdir_p!(Path.join(dir, ".claude-plugin"))
    File.write!(Path.join([dir, ".claude-plugin", "plugin.json"]), ~s({"name": "p"}))
    dir
  end

  test "init-writes-the-settings: criterion 1 init writes the manager, agents and chat, and plugin and server only when given",
       %{root: root, repo: repo, config: config} do
    # The repo defaults to the current directory.
    assert {:ok, _said} = Workflow.Init.run([], repo)
    written = config |> File.read!() |> Jason.decode!()

    claude = %{"provider" => "claude-code"}

    assert written == %{
             "manager" => %{
               "agent" => claude,
               "repo" => repo,
               "agents" => %{"coder" => claude, "reviewer" => claude, "qa" => claude}
             },
             "recipients" => %{"me" => %{"kind" => "chat"}}
           }

    File.rm!(config)
    dir = plugin(root)

    assert {:ok, _said} =
             Workflow.Init.run(
               [
                 "--repo",
                 repo,
                 "--plugin",
                 dir,
                 "--server",
                 "wss://loop.example/socket/websocket",
                 "--project",
                 "p-1"
               ],
               root
             )

    written = config |> File.read!() |> Jason.decode!()
    assert written["manager"]["repo"] == repo
    assert written["plugin"] == dir

    assert written["server"] == %{
             "url" => "wss://loop.example/socket/websocket",
             "project_id" => "p-1"
           }

    # The file is one the loop boots with.
    assert :ok = Workflow.ConfigFile.load()
  after
    for key <- [:manager, :recipients, :server, :plugin],
        do: Application.delete_env(:workflow, key)
  end

  test "init-writes-the-settings: criterion 1 the mix task and the release's `workflow init` run the same init",
       %{repo: repo, config: config} do
    said = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Workflow.Init.run(["--repo", repo]) end)

    assert said =~ config
    assert %{"manager" => %{"repo" => ^repo}} = config |> File.read!() |> Jason.decode!()

    env = File.read!(Path.join(File.cwd!(), "rel/env.sh.eex"))
    assert env =~ ~s(if [ "$1" = "init" ]; then)
    assert env =~ ~s|eval "Workflow.Init.main()"|
  end

  test "init-writes-the-settings: criterion 2 an existing config.json is refused with its path and left unchanged",
       %{repo: repo, config: config} do
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, ~s({"mine": true}))

    assert {:error, why} = Workflow.Init.run(["--repo", repo], repo)
    assert why =~ config
    assert File.read!(config) == ~s({"mine": true})
  end

  test "init-writes-the-settings: criterion 3 each bad flag is refused naming that flag, and nothing is written",
       %{root: root, repo: repo, config: config} do
    not_git = Path.join(root, "not-git")
    File.mkdir_p!(not_git)
    no_manifest = Path.join(root, "empty-plugin")
    File.mkdir_p!(no_manifest)

    for {args, flag} <- [
          {["--repo", not_git], "--repo"},
          {["--repo", repo, "--plugin", no_manifest], "--plugin"},
          {["--repo", repo, "--server", "wss://loop.example/socket/websocket"], "--server"},
          {["--repo", repo, "--project", "p-1"], "--project"}
        ] do
      assert {:error, why} = Workflow.Init.run(args, root)
      assert why =~ flag, "#{inspect(args)} gave #{inspect(why)}"
      refute File.exists?(config)
    end
  end

  test "init-writes-the-settings: criterion 4 init prints what it wrote, and sign-in only when a server was given",
       %{root: root, repo: repo, config: config} do
    assert {:ok, said} = Workflow.Init.run(["--repo", repo], root)
    assert said =~ config
    assert said =~ repo
    refute said =~ "workflow sign-in"
    assert said =~ "brew services start codemyspec"

    File.rm!(config)

    assert {:ok, said} =
             Workflow.Init.run(
               [
                 "--repo",
                 repo,
                 "--server",
                 "wss://loop.example/socket/websocket",
                 "--project",
                 "p"
               ],
               root
             )

    assert said =~ "wss://loop.example/socket/websocket"
    sign_in = :binary.match(said, "workflow sign-in")
    start = :binary.match(said, "brew services start codemyspec")
    assert sign_in != :nomatch and start != :nomatch and sign_in < start
  end

  test "init-writes-the-settings: criterion 5 README's install section lists brew install, init, sign-in, then starting the service" do
    [install | _] =
      Path.join(File.cwd!(), "README.md")
      |> File.read!()
      |> String.split(~r/^## /m)
      |> Enum.drop(1)

    assert install =~ ~r/^Install\n/

    at =
      for step <- [
            "brew install",
            "workflow init",
            "workflow sign-in",
            "brew services start codemyspec"
          ] do
        assert {at, _} = :binary.match(install, step), "#{step} is not in the install section"
        at
      end

    assert at == Enum.sort(at)
  end
end
