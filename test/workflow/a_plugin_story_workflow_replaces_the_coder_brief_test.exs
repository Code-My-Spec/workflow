defmodule Workflow.APluginStoryWorkflowReplacesTheCoderBriefTest do
  # Not async: the plugin is the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  test "workflows-are-data: criterion 4 a plugin's own story workflow with a changed coder brief is what the next story's coder is told",
       %{tmp_dir: dir} do
    plugin = Path.join(dir, "plugin")
    File.mkdir_p!(Path.join(plugin, ".claude-plugin"))
    File.write!(Path.join(plugin, ".claude-plugin/plugin.json"), ~s({"name": "p"}))
    File.mkdir_p!(Path.join(plugin, "workflows"))

    brief = "Make the tests pass, and say so in rhyme."

    File.write!(
      Path.join(plugin, "workflows/story.json"),
      Jason.encode!(%{
        "name" => "story",
        "steps" => [
          %{
            "name" => "specify",
            "actor" => "qa",
            "agent" => %{"brief" => "Write a test.", "tools" => ["read", "edit", "write", "bash"]}
          },
          %{"name" => "run", "actor" => "system"},
          %{
            "name" => "work",
            "actor" => "coder",
            "agent" => %{"brief" => brief, "tools" => ["read", "edit", "write", "bash"]}
          }
        ]
      })
    )

    Application.put_env(:workflow, :plugin, plugin)
    on_exit(fn -> Application.delete_env(:workflow, :plugin) end)

    assert {:ok, %{name: "story", steps: steps}} = Workflow.Workflows.load("story")
    coder = Enum.find(steps, &(&1.name == "work"))
    assert coder.agent.brief =~ brief
  end
end
