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

  defp posted(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Workflow.Router.call(Workflow.Router.init([]))
  end

  test "the-loop-does-no-deploys: a config.json with \"deploy\" and \"go\" boots, logs one ignored line per key, refuses a provision, and has no POST /work/go",
       %{tmp_dir: dir} do
    works = Path.join(dir, "works")
    File.mkdir_p!(Path.dirname(config_path(works)))
    hash = Base.encode16(:crypto.hash(:sha256, "owner word"), case: :lower)

    File.write!(
      config_path(works),
      Jason.encode!(%{"deploy" => "uat", "go" => hash, "manager" => %{"repo" => dir}})
    )

    Application.delete_env(:workflow, :deploy)
    on_exit(fn -> Application.delete_env(:workflow, :deploy) end)

    {started, log} =
      ExUnit.CaptureLog.with_log(fn -> start_with(works_dir: works) end)

    # Criterion 3: it boots, with one line per old key saying it is ignored, and keeps neither.
    assert {:ok, _apps} = started
    lines = String.split(log, "\n")
    assert Enum.count(lines, &(&1 =~ ~s("deploy") and &1 =~ "ignored")) == 1
    assert Enum.count(lines, &(&1 =~ ~s("go") and &1 =~ "ignored")) == 1
    refute log =~ hash
    assert Application.get_env(:workflow, :deploy) == nil
    assert Application.get_env(:workflow, :go) == nil

    # Criterion 1: a work of kind provision is refused, handed in or looked at.
    refute "provision" in Workflow.Run.kinds()

    assert posted(:post, "/work/run", %{"kind" => "provision", "id" => "p1", "root" => dir}).status ==
             422

    looked =
      conn(:get, "/works/p1?kind=provision&root=#{URI.encode_www_form(dir)}")
      |> Workflow.Router.call(Workflow.Router.init([]))

    assert looked.status == 422

    # Criterion 1: the manager's tool schemas offer no provision kind and no target.
    listed =
      posted(:post, "/mcp/manager", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert %{"result" => %{"tools" => [_ | _] = tools}} = Jason.decode!(listed.resp_body)

    for %{"inputSchema" => schema} <- tools, properties = schema["properties"] || %{} do
      refute Map.has_key?(properties, "target")
      refute "provision" in (get_in(properties, ["kind", "enum"]) || [])
    end

    # Criterion 2: POST /work/go is an unknown route, and no work moves on.
    go =
      posted(:post, "/work/go", %{
        "kind" => "provision",
        "id" => "p1",
        "root" => dir,
        "word" => "owner word"
      })

    assert go.status == 404
    refute Jason.decode!(go.resp_body)["error"] =~ "/work/go"
    refute File.exists?(Path.join(works, "p1.json"))
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
