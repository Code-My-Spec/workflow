defmodule Workflow.PluginMcpTest do
  # Not async: the plugin folder and Alloy's stand-in are set for the whole application.
  use ExUnit.Case

  alias Workflow.Agents

  @moduletag :tmp_dir

  # An MCP server over HTTP with one tool, answering the list as an event stream.
  defmodule FakeHttp do
    import Plug.Conn

    def init(options), do: options

    def call(conn, _options) do
      {:ok, body, conn} = read_body(conn)

      case Jason.decode!(body) do
        %{"id" => id, "method" => "initialize"} ->
          conn |> put_resp_header("mcp-session-id", "s1") |> answer(id, %{"capabilities" => %{}})

        %{"method" => "notifications/initialized"} ->
          send_resp(conn, 202, "")

        %{"id" => id, "method" => "tools/list"} ->
          tool = %{
            "name" => "shout",
            "description" => "Shouts.",
            "inputSchema" => %{"type" => "object"}
          }

          message =
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => [tool]}})

          conn
          |> put_resp_content_type("text/event-stream")
          |> send_resp(200, "event: message\ndata: #{message}\n\n")

        %{"id" => id, "method" => "tools/call", "params" => %{"arguments" => %{"text" => text}}} ->
          ["s1"] = get_req_header(conn, "mcp-session-id")
          answer(conn, id, %{"content" => [%{"type" => "text", "text" => String.upcase(text)}]})
      end
    end

    defp answer(conn, id, result) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
    end
  end

  # An MCP server over stdio with one tool, `echo`.
  @stdio ~S"""
  #!/bin/sh
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
    [ -z "$id" ] && continue
    case "$line" in
      *'"initialize"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"capabilities\":{}}}" ;;
      *'"tools/list"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echoes.\",\"inputSchema\":{\"type\":\"object\"}}]}}" ;;
      *'"tools/call"'*)
        text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
        echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echoed $text\"}]}}" ;;
    esac
  done
  """

  test "loop-waits-on-evidence: criterion 8 a plugin's .mcp.json gives each Claude Code agent its MCP servers' tools",
       %{tmp_dir: dir} do
    test = self()
    before = Application.get_env(:workflow, :plugin)

    on_exit(fn ->
      Application.delete_env(:workflow, :alloy_run)

      if before,
        do: Application.put_env(:workflow, :plugin, before),
        else: Application.delete_env(:workflow, :plugin)
    end)

    server =
      start_supervised!({Bandit, plug: FakeHttp, ip: :loopback, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    plugin = Path.join(dir, "plugin")
    File.mkdir_p!(plugin)
    File.write!(Path.join(plugin, "fake-mcp.sh"), @stdio)

    File.write!(
      Path.join(plugin, ".mcp.json"),
      Jason.encode!(%{
        "mcpServers" => %{
          "fake" => %{"command" => "sh", "args" => ["${CLAUDE_PLUGIN_ROOT}/fake-mcp.sh"]},
          "web" => %{"type" => "http", "url" => "http://127.0.0.1:#{port}/mcp"},
          "broken" => %{"command" => Path.join(dir, "no-such-server")}
        }
      })
    )

    Application.put_env(:workflow, :plugin, plugin)

    Application.put_env(:workflow, :alloy_run, fn _message, opts ->
      send(test, {:alloy_opts, opts})
      {:ok, %{status: :completed, turns: 1, messages: []}}
    end)

    root = Path.join(dir, "repo")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: root)

    step = %{
      name: "work",
      actor: :coder,
      note: "Fix it.",
      agent: %{tools: [:bash], brief: "Fix it."}
    }

    Agents.run(step, %{
      "id" => "mcp-tools",
      "root" => root,
      "agent" => %{"provider" => "claude-code"}
    })

    assert_receive {:alloy_opts, opts}, 5_000
    tools = for %Alloy.Tool.Inline{} = tool <- opts[:tools], into: %{}, do: {tool.name, tool}

    assert {:ok, "echoed hi"} = tools["mcp__fake__echo"].execute.(%{"text" => "hi"}, %{})
    assert {:ok, "HI"} = tools["mcp__web__shout"].execute.(%{"text" => "hi"}, %{})
  end
end
