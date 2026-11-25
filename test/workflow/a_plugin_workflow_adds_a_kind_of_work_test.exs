defmodule Workflow.APluginWorkflowAddsAKindOfWorkTest do
  # Not async: the plugin is the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  test "workflows-are-data: criterion 3 a plugin with a design-pass workflow file lets the manager hand in a design pass",
       %{tmp_dir: dir} do
    plugin = Path.join(dir, "plugin")
    File.mkdir_p!(Path.join(plugin, ".claude-plugin"))
    File.write!(Path.join(plugin, ".claude-plugin/plugin.json"), ~s({"name": "p"}))
    File.mkdir_p!(Path.join(plugin, "workflows"))

    File.write!(
      Path.join(plugin, "workflows/design-pass.json"),
      Jason.encode!(%{
        "name" => "design-pass",
        "steps" => [
          %{
            "name" => "specify",
            "actor" => "qa",
            "agent" => %{"brief" => "Design it.", "tools" => ["read", "edit"]}
          },
          %{"name" => "run", "actor" => "system"}
        ]
      })
    )

    Application.put_env(:workflow, :plugin, plugin)
    on_exit(fn -> Application.delete_env(:workflow, :plugin) end)

    assert "design-pass" in Workflow.Run.kinds()
    # The loop's own kinds are still there beside it.
    assert Enum.all?(["story", "issue", "journey"], &(&1 in Workflow.Run.kinds()))
  end
end
