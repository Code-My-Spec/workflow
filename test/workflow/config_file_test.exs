defmodule Workflow.ConfigFileTest do
  # Not async: the application is stopped and started again with its settings swapped.
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  @moduletag :tmp_dir

  # The file sits beside the works directory, where the service keeps its own files.
  # Worked out from the works directory the test will start with, without setting it
  # before `restart_with/1` has saved the settings it puts back afterwards.
  defp config_path(works_dir), do: Path.join(Path.dirname(works_dir), "config.json")

  defp restart_with(env) do
    {:ok, _started} = start_with(env)
  end

  # Stops the application and starts it again with `env`, answering how the start went.
  # The settings it swaps are put back, and the application started, when the test ends.
  defp start_with(env) do
    keys = [:works_dir, :manager, :recipients, :instructions, :go, :plugin]
    before = for key <- keys, do: {key, Application.fetch_env(:workflow, key)}

    on_exit(fn ->
      Application.stop(:workflow)

      for {key, saved} <- before do
        case saved do
          {:ok, value} -> Application.put_env(:workflow, key, value)
          :error -> Application.delete_env(:workflow, key)
        end
      end

      {:ok, _started} = Application.ensure_all_started(:workflow)
    end)

    Application.stop(:workflow)
    Application.delete_env(:workflow, :manager)
    Application.delete_env(:workflow, :recipients)
    Application.delete_env(:workflow, :instructions)
    Application.delete_env(:workflow, :go)
    Application.delete_env(:workflow, :plugin)
    for {key, value} <- env, do: Application.put_env(:workflow, key, value)
    Application.ensure_all_started(:workflow)
  end

  defp post_manager(body) do
    conn(:post, "/manager", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Workflow.Router.call(Workflow.Router.init([]))
  end

  defp initialize do
    conn(
      :post,
      "/mcp",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0"}
        }
      })
    )
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> Workflow.Router.call(Workflow.Router.init([]))
  end

  test "go-needs-the-owners-word: the \"go\" hash in config.json is read at boot and decides the go",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    File.mkdir_p!(Path.dirname(config_path(works)))
    hash = Base.encode16(:crypto.hash(:sha256, "owner word"), case: :lower)
    File.write!(config_path(works), Jason.encode!(%{"go" => hash}))

    restart_with(works_dir: works)

    conn =
      conn(:post, "/work/go", Jason.encode!(%{"id" => "p1", "word" => "a guess"}))
      |> put_req_header("content-type", "application/json")
      |> Workflow.Router.call(Workflow.Router.init([]))

    # Refused for the word, not for want of a hash.
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] =~ "owner's word"
    refute conn.resp_body =~ hash
  end

  test "config-file: criterion 1 - POST /manager answers after a plain start with a config file naming a manager",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    File.mkdir_p!(Path.dirname(config_path(works)))

    File.write!(
      config_path(works),
      Jason.encode!(%{
        "manager" => %{"agent" => %{"provider" => "claude-code"}, "repo" => "/some/repo"}
      })
    )

    restart_with(works_dir: works)

    conn = post_manager(%{"say" => "hello"})

    refute conn.status == 404
  end

  test "config-file: criterion 2 - a say to a recipient named in the config file is delivered according to its kind",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    File.mkdir_p!(Path.dirname(config_path(works)))

    File.write!(
      config_path(works),
      Jason.encode!(%{
        "recipients" => %{"coder" => %{"kind" => "codex", "thread" => "thread-7"}}
      })
    )

    restart_with(works_dir: works)

    test = self()

    Application.put_env(:workflow, :cmd, fn command, args, _opts ->
      send(test, {:ran, command, args})
      {"", 0}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    assert {:ok, _answer} = Workflow.Messages.say("coder", "chat", "please look at this")

    assert_received {:ran, "codex",
                     ["queue", "--thread", "thread-7", "--message", "please look at this"]}
  end

  test "prod-waits-for-the-owner: criterion 5 - \"deploy\": \"prod\" in config.json refuses the start, saying a landing never deploys prod by itself",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    File.mkdir_p!(Path.dirname(config_path(works)))
    File.write!(config_path(works), Jason.encode!(%{"deploy" => "prod"}))

    # A refused start must leave no deploy setting behind for the tests after it.
    Application.delete_env(:workflow, :deploy)
    on_exit(fn -> Application.delete_env(:workflow, :deploy) end)

    assert {:error, {:workflow, reason}} = start_with(works_dir: works)
    assert inspect(reason) =~ "never deploys prod by itself"
  end

  test "config-file: criterion 3 - with no config file, the service starts and works as it does today",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    refute File.exists?(config_path(works))

    # Settings given the old way, with -e, and no file beside the works directory.
    restart_with(
      works_dir: works,
      recipients: %{"coder" => %{"kind" => "codex", "thread" => "thread-9"}}
    )

    assert Process.whereis(Workflow.Supervisor)

    # No manager anywhere: as today, there is none.
    conn = post_manager(%{"say" => "hello"})
    assert conn.status == 404
    assert %{"error" => "no manager is configured"} = Jason.decode!(conn.resp_body)

    # The recipients given by the settings still deliver by their kind.
    test = self()

    Application.put_env(:workflow, :cmd, fn command, args, _opts ->
      send(test, {:ran, command, args})
      {"", 0}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    assert {:ok, _answer} = Workflow.Messages.say("coder", "chat", "still works")
    assert_received {:ran, "codex", ["queue", "--thread", "thread-9", "--message", "still works"]}
  end

  test "chat-brief: criterion 1 - the answer to an MCP initialize carries the contents of the file named by \"instructions\" in config.json",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    brief = Path.join(dir, "brief.md")
    File.write!(brief, "You are the chat for this project. Ask before you pass work on.\n")
    File.mkdir_p!(Path.dirname(config_path(works)))
    File.write!(config_path(works), Jason.encode!(%{"instructions" => brief}))

    restart_with(works_dir: works)

    conn = initialize()

    assert conn.status == 200
    assert %{"result" => result} = Jason.decode!(conn.resp_body)
    assert result["instructions"] == File.read!(brief)
  end

  test "config-file: criterion 4 - a config file that is not valid JSON stops the boot with a message that names the file",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    file = config_path(works)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "{ this is not json")

    keys = [:works_dir, :manager, :recipients]
    before = for key <- keys, do: {key, Application.fetch_env(:workflow, key)}

    on_exit(fn ->
      Application.stop(:workflow)

      for {key, saved} <- before do
        case saved do
          {:ok, value} -> Application.put_env(:workflow, key, value)
          :error -> Application.delete_env(:workflow, key)
        end
      end

      {:ok, _started} = Application.ensure_all_started(:workflow)
    end)

    Application.stop(:workflow)
    Application.delete_env(:workflow, :manager)
    Application.delete_env(:workflow, :recipients)
    Application.put_env(:workflow, :works_dir, works)

    {result, _log} =
      ExUnit.CaptureLog.with_log(fn -> Application.ensure_all_started(:workflow) end)

    assert {:error, {:workflow, reason}} = result
    assert inspect(reason) =~ file
  end

  test "chat-brief: criterion 2 - a brief that starts with front matter is sent without it",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    brief = Path.join(dir, "SKILL.md")

    File.write!(brief, """
    ---
    name: chat
    description: The chat's brief.
    ---
    You are the chat for this project.
    Ask before you pass work on.
    """)

    File.mkdir_p!(Path.dirname(config_path(works)))
    File.write!(config_path(works), Jason.encode!(%{"instructions" => brief}))

    restart_with(works_dir: works)

    conn = initialize()

    assert conn.status == 200
    assert %{"result" => result} = Jason.decode!(conn.resp_body)

    assert result["instructions"] ==
             "You are the chat for this project.\nAsk before you pass work on.\n"
  end

  test "chat-brief: criterion 3 - an instructions file that is not there stops the boot with a message that names it",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    brief = Path.join(dir, "missing-brief.md")
    refute File.exists?(brief)
    File.mkdir_p!(Path.dirname(config_path(works)))
    File.write!(config_path(works), Jason.encode!(%{"instructions" => brief}))

    {result, _log} = ExUnit.CaptureLog.with_log(fn -> start_with(works_dir: works) end)

    assert {:error, {:workflow, reason}} = result
    assert inspect(reason) =~ brief
  end

  defp refused_plugin(dir, plugin, said) do
    works = Path.join(dir, "works")
    File.mkdir_p!(Path.dirname(config_path(works)))
    File.write!(config_path(works), Jason.encode!(%{"plugin" => plugin}))

    {result, _log} = ExUnit.CaptureLog.with_log(fn -> start_with(works_dir: works) end)

    assert {:error, {:workflow, reason}} = result
    assert inspect(reason) =~ plugin
    assert inspect(reason) =~ said
  end

  test "plugin-is-the-skills: criterion 3 - a plugin folder with no .claude-plugin/plugin.json stops the boot saying so",
       %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "bare/skills/coder"))
    refused_plugin(dir, Path.join(dir, "bare"), "has no .claude-plugin/plugin.json")
  end

  test "plugin-is-the-skills: criterion 3 - a plugin that names no folder stops the boot saying so",
       %{tmp_dir: dir} do
    refused_plugin(dir, Path.join(dir, "nowhere"), "names no folder")
  end

  test "plugin-is-the-skills: criterion 2 - a plugin relative to the manager's repo is kept as its absolute folder",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "plugins/mine/.claude-plugin"))
    File.write!(Path.join(repo, "plugins/mine/.claude-plugin/plugin.json"), ~s({"name": "mine"}))
    File.mkdir_p!(Path.dirname(config_path(works)))

    File.write!(
      config_path(works),
      Jason.encode!(%{"plugin" => "plugins/mine", "manager" => %{"repo" => repo}})
    )

    restart_with(works_dir: works)
    assert Application.get_env(:workflow, :plugin) == Path.join(repo, "plugins/mine")
  end

  test "chat-brief: criterion 4 - with no instructions in the config, initialize has no instructions",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    File.mkdir_p!(Path.dirname(config_path(works)))

    File.write!(
      config_path(works),
      Jason.encode!(%{"recipients" => %{"coder" => %{"kind" => "codex", "thread" => "t-1"}}})
    )

    restart_with(works_dir: works)

    conn = initialize()

    assert conn.status == 200
    assert %{"result" => result} = Jason.decode!(conn.resp_body)
    refute Map.has_key?(result, "instructions")
    assert result["serverInfo"]["name"] == "workflow"

    # The rest of the MCP answers as today.
    tools =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
      )
      |> put_req_header("content-type", "application/json")
      |> Workflow.Router.call(Workflow.Router.init([]))

    assert %{"result" => %{"tools" => listed}} = Jason.decode!(tools.resp_body)
    assert Enum.map(listed, & &1["name"]) == ["say", "inbox"]
  end
end
