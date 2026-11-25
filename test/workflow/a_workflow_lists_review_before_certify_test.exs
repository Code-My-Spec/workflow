defmodule Workflow.AWorkflowListsReviewBeforeCertifyTest do
  # Not async: the plugin is the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  defp step(name, actor), do: %{"name" => name, "actor" => actor}

  defp agent(name, actor, tools),
    do: Map.put(step(name, actor), "agent", %{"brief" => "Do #{name}.", "tools" => tools})

  defp current(results) do
    Workflow.current(Workflow.Story, %{
      id: "s1",
      head: "h",
      main: "trunk",
      criteria: ["the user logs in"],
      named: [1],
      results: %{"h" => results}
    })
  end

  test "workflows-are-data: criterion 5 a workflow that lists review before certify runs its steps in that order",
       %{tmp_dir: dir} do
    plugin = Path.join(dir, "plugin")
    File.mkdir_p!(Path.join(plugin, ".claude-plugin"))
    File.write!(Path.join(plugin, ".claude-plugin/plugin.json"), ~s({"name": "p"}))
    File.mkdir_p!(Path.join(plugin, "workflows"))

    File.write!(
      Path.join(plugin, "workflows/story.json"),
      Jason.encode!(%{
        "name" => "story",
        "steps" => [
          agent("specify", "qa", ["read", "edit"]),
          step("run", "system"),
          agent("work", "coder", ["read", "edit"]),
          agent("review", "reviewer", ["read", "bash"]),
          step("certify", "system"),
          step("promote", "system"),
          step("ci", "external")
        ]
      })
    )

    Application.put_env(:workflow, :plugin, plugin)
    on_exit(fn -> Application.delete_env(:workflow, :plugin) end)

    green = %{"run" => %{"status" => "passed"}, "by" => %{"step" => "work"}}

    # Review comes first, and does what it does today: it asks for a review.
    assert %{name: "review", actor: :reviewer, note: note} = current(green)
    assert note =~ "Review the story"

    # Once reviewed, certify is next.
    reviewed = Map.put(green, "review", %{"status" => "pass"})
    assert %{name: "certify", actor: :system} = current(reviewed)

    # A failed review still sends the work back to the coder, with its note.
    failed = Map.put(green, "review", %{"status" => "fail", "note" => "no"})
    assert %{name: "work", note: "The review failed: no"} = current(failed)

    assert Enum.map(Workflow.Template.steps(Workflow.Story), & &1.name) ==
             ~w(specify run work review certify promote ci)
  end
end
