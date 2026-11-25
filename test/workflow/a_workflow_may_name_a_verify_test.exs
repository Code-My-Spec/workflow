defmodule Workflow.AWorkflowMayNameAVerifyTest do
  # Not async: the plugin is the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  defp plugin_with(dir, name, workflow) do
    plugin = Path.join(dir, "plugin-#{name}")
    File.mkdir_p!(Path.join(plugin, ".claude-plugin"))
    File.write!(Path.join(plugin, ".claude-plugin/plugin.json"), ~s({"name": "p"}))
    File.mkdir_p!(Path.join(plugin, "workflows"))
    File.write!(Path.join(plugin, "workflows/check.json"), Jason.encode!(workflow))
    Application.put_env(:workflow, :plugin, plugin)
    on_exit(fn -> Application.delete_env(:workflow, :plugin) end)
  end

  # The work, its one step `run` already done: nothing but the end is left.
  defp current do
    Workflow.current({Workflow.Story, "check"}, %{
      id: "s1",
      head: "h",
      main: "trunk",
      criteria: ["the user logs in"],
      named: [1],
      results: %{"h" => %{"run" => %{"status" => "passed"}}}
    })
  end

  test "workflows-are-data: criterion 7 a workflow with no verify is done at its last step; one that names a verify runs it once at the end",
       %{tmp_dir: dir} do
    steps = [%{"name" => "run", "actor" => "system"}]

    # With none, the work is done when its last step is.
    plugin_with(dir, "none", %{"name" => "check", "steps" => steps})
    assert current() == nil

    # With one, the work is not done until the verify has run.
    plugin_with(dir, "verified", %{"name" => "check", "steps" => steps, "verify" => "certify"})
    assert %{name: "verify", actor: :system} = current()
  end
end
