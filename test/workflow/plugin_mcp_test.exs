defmodule Workflow.PluginMcpTest do
  # Not async: the plugin folder is set for the whole application.
  use ExUnit.Case

  @moduletag :tmp_dir

  test "loop-waits-on-evidence: criterion 8 a plugin's .mcp.json gives each Claude Code agent its MCP servers",
       %{tmp_dir: dir} do
    before = Application.get_env(:workflow, :plugin)

    on_exit(fn ->
      if before,
        do: Application.put_env(:workflow, :plugin, before),
        else: Application.delete_env(:workflow, :plugin)
    end)

    mcp = Path.join(dir, ".mcp.json")

    File.write!(
      mcp,
      ~s({"mcpServers": {"tidewave": {"type": "http", "url": "http://localhost:4000/tidewave/mcp"}}})
    )

    Application.put_env(:workflow, :plugin, dir)

    step = %{name: "work", actor: :coder, note: "Fix it.", agent: %{}}
    work = %{"root" => dir, "agent" => %{"provider" => "claude-code"}}

    assert {:ok, {AlloyClaudeCode, config}} = Workflow.Agents.provider(step, work)
    assert config.settings_path == mcp
  end
end
