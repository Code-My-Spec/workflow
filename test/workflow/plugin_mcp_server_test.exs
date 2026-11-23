defmodule Workflow.PluginMcpServerTest do
  # Not async: the plugin folder, the server and the manager are the whole application's.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  @token "tok-secret-4711"

  # An MCP server over stdio with one tool, `whoami`, that answers the three
  # arguments it was started with: the url, the project id and the token.
  @stdio ~S"""
  #!/bin/sh
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
    [ -z "$id" ] && continue
    case "$line" in
      *'"initialize"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"capabilities\":{}}}" ;;
      *'"tools/list"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"whoami\",\"description\":\"Says who.\",\"inputSchema\":{\"type\":\"object\"}}]}}" ;;
      *'"tools/call"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"$1 $2 $3\"}]}}" ;;
    esac
  done
  """

  # Puts each setting for the test only, putting back what was there after.
  defp settings(settings) do
    was = for {key, _value} <- settings, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    for {key, value} <- settings do
      if value,
        do: Application.put_env(:workflow, key, value),
        else: Application.delete_env(:workflow, key)
    end
  end

  # A plugin folder with the fake server and a `.mcp.json` of `servers`.
  defp plugin(dir, servers) do
    plugin = Path.join(dir, "plugin")
    File.mkdir_p!(plugin)
    File.write!(Path.join(plugin, "fake-mcp.sh"), @stdio)
    File.write!(Path.join(plugin, ".mcp.json"), Jason.encode!(%{"mcpServers" => servers}))
    plugin
  end

  @whoami %{
    "command" => "sh",
    "args" => [
      "${CLAUDE_PLUGIN_ROOT}/fake-mcp.sh",
      "${WORKFLOW_SERVER_URL}",
      "${WORKFLOW_PROJECT_ID}",
      "${WORKFLOW_SERVER_TOKEN}"
    ]
  }

  # The loop's server, with a fake sign-in held in the test's own state dir.
  defp server(dir, token) do
    server = %{
      "url" => "wss://loop.example/socket/websocket",
      "project_id" => "p-7",
      "state_dir" => Path.join(dir, "state")
    }

    sign_in(server, token)
    server
  end

  defp sign_in(server, token) do
    hash = :crypto.hash(:sha256, "https://loop.example") |> Base.encode16(case: :lower)
    File.mkdir_p!(server["state_dir"])

    File.write!(
      Path.join(server["state_dir"], "harness_oauth_#{hash}.json"),
      Jason.encode!(%{
        "access_token" => token,
        "refresh_token" => "refresh",
        "expires_at" => System.system_time(:second) + 3600,
        "client_id" => "c",
        "client_secret" => "s"
      })
    )
  end

  defp named(tools),
    do: for(%Alloy.Tool.Inline{} = tool <- tools, into: %{}, do: {tool.name, tool})

  defp manager(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: repo)
    test = self()

    settings(
      manager: %{"agent" => %{"provider" => "claude-code"}, "repo" => repo},
      works_dir: Path.join(dir, "works"),
      manager_run: fn _message, opts ->
        send(test, {:manager_opts, opts})
        {:ok, %{text: "done", messages: []}}
      end
    )

    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)
    repo
  end

  test "plugin-mcp-reaches-the-server: criterion 1 the manager's tool list includes the plugin's MCP server tools beside its own",
       %{tmp_dir: dir} do
    servers = %{"fake" => %{"command" => "sh", "args" => ["${CLAUDE_PLUGIN_ROOT}/fake-mcp.sh"]}}
    settings(plugin: plugin(dir, servers), server: nil)
    manager(dir)

    Workflow.Manager.tell("hello")

    assert_receive {:manager_opts, opts}, 5_000
    tools = named(opts[:tools])
    assert tools["mcp__fake__whoami"]
    assert tools["hand_in"] && tools["tell"] && tools["message_chat"]
  end

  test "plugin-mcp-reaches-the-server: criterion 2 the server's url, project_id and a fresh sign-in token are put in the plugin's .mcp.json",
       %{tmp_dir: dir} do
    server = server(dir, @token)
    settings(plugin: plugin(dir, %{"cms" => @whoami}), server: server)

    whoami = named(Workflow.Mcp.tools(:manager))["mcp__cms__whoami"]
    assert {:ok, "https://loop.example p-7 #{@token}"} == whoami.execute.(%{}, %{})

    # Signed in afresh for each session: a refreshed token is the one sent next.
    sign_in(server, "tok-renewed")
    assert {:ok, "https://loop.example p-7 tok-renewed"} == whoami.execute.(%{}, %{})
  end

  test "plugin-mcp-reaches-the-server: criterion 3 the server token is in no log line and no conversation file",
       %{tmp_dir: dir} do
    servers = %{
      "cms" => @whoami,
      # A server that fails, started with the token: its failure is logged.
      "broken" => %{"command" => "sh", "args" => ["-c", "exit 3", "${WORKFLOW_SERVER_TOKEN}"]}
    }

    settings(plugin: plugin(dir, servers), server: server(dir, @token))
    repo = manager(dir)

    log =
      capture_log([level: :debug], fn ->
        Workflow.Manager.tell("hello")
        assert_receive {:manager_opts, opts}, 5_000
        whoami = named(opts[:tools])["mcp__cms__whoami"]
        assert {:ok, "https://loop.example p-7 " <> @token} = whoami.execute.(%{}, %{})
      end)

    assert log =~ "broken"
    refute log =~ @token

    conversation = Workflow.Conversation.path(repo, "manager")
    assert File.read!(conversation) =~ "mcp__cms__whoami"
    refute File.read!(conversation) =~ @token
  end

  test "plugin-mcp-reaches-the-server: criterion 4 with no server configured an entry naming it is left out with one warning, and the rest load",
       %{tmp_dir: dir} do
    servers = %{
      "cms" => @whoami,
      "fake" => %{"command" => "sh", "args" => ["${CLAUDE_PLUGIN_ROOT}/fake-mcp.sh"]}
    }

    settings(plugin: plugin(dir, servers), server: nil)
    manager(dir)

    log =
      capture_log(fn ->
        assert "done" == Workflow.Manager.tell("hello")
        assert_receive {:manager_opts, opts}, 5_000
        tools = named(opts[:tools])
        assert tools["mcp__fake__whoami"]
        refute tools["mcp__cms__whoami"]
      end)

    assert [_one] = Regex.scan(~r/MCP server cms\b/, log)
  end

  test "plugin-mcp-reaches-the-server: an entry with roles [\"manager\"] reaches only the manager; one with no roles reaches every agent",
       %{tmp_dir: dir} do
    servers = %{
      "issues" => %{
        "command" => "sh",
        "args" => ["${CLAUDE_PLUGIN_ROOT}/fake-mcp.sh"],
        "roles" => ["manager"]
      },
      "fake" => %{"command" => "sh", "args" => ["${CLAUDE_PLUGIN_ROOT}/fake-mcp.sh"]}
    }

    settings(plugin: plugin(dir, servers), server: nil)
    repo = manager(dir)

    Workflow.Manager.tell("hello")
    assert_receive {:manager_opts, opts}, 5_000
    managed = named(opts[:tools])
    assert managed["mcp__issues__whoami"]
    assert managed["mcp__fake__whoami"]

    test = self()

    settings(
      alloy_run: fn _message, opts ->
        send(test, {:alloy_opts, opts})
        {:ok, %{status: :completed, turns: 1, messages: []}}
      end
    )

    step = %{
      name: "work",
      actor: :coder,
      note: "Fix it.",
      agent: %{tools: [:bash], brief: "Fix it."}
    }

    Workflow.Agents.run(step, %{
      "id" => "mcp-roles",
      "root" => repo,
      "agent" => %{"provider" => "claude-code"}
    })

    assert_receive {:alloy_opts, opts}, 5_000
    coded = named(opts[:tools])
    assert coded["mcp__fake__whoami"]
    refute coded["mcp__issues__whoami"]
  end

  # An MCP server over stdio whose tool reports what its env holds.
  @env_stdio ~S"""
  #!/bin/sh
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
    [ -z "$id" ] && continue
    if [ "$CMS_TOKEN" = "EXPECTED_TOKEN_HERE" ]; then same=token-matches; else same=token-differs; fi
    case "$line" in
      *'"initialize"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"capabilities\":{}}}" ;;
      *'"tools/list"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"env\",\"description\":\"Env.\",\"inputSchema\":{\"type\":\"object\"}}]}}" ;;
      *'"tools/call"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"$CMS_SERVER_URL $CMS_PROJECT_ID $same $WORKFLOW_TEST_KEPT\"}]}}" ;;
    esac
  done
  """

  test "plugin-mcp-reaches-the-server: a command server's env has the placeholders put in, its keys over the loop's, and the rest of the loop's env",
       %{tmp_dir: dir} do
    servers = %{
      "issues" => %{
        "command" => "sh",
        "args" => ["${CLAUDE_PLUGIN_ROOT}/issues.sh"],
        "env" => %{
          "CMS_SERVER_URL" => "${WORKFLOW_SERVER_URL}",
          "CMS_PROJECT_ID" => "${WORKFLOW_PROJECT_ID}",
          "CMS_TOKEN" => "${WORKFLOW_SERVER_TOKEN}"
        },
        "roles" => ["manager"]
      }
    }

    plugin = plugin(dir, servers)

    File.write!(
      Path.join(plugin, "issues.sh"),
      String.replace(@env_stdio, "EXPECTED_TOKEN_HERE", @token)
    )

    settings(plugin: plugin, server: server(dir, @token))

    for {key, value} <- [{"WORKFLOW_TEST_KEPT", "kept"}, {"CMS_PROJECT_ID", "overridden"}] do
      was = System.get_env(key)
      System.put_env(key, value)
      on_exit(fn -> if was, do: System.put_env(key, was), else: System.delete_env(key) end)
    end

    env = named(Workflow.Mcp.tools(:manager))["mcp__issues__env"]
    assert {:ok, "https://loop.example p-7 token-matches kept"} == env.execute.(%{}, %{})
  end
end
