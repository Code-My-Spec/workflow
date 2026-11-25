defmodule Workflow.WorkflowNamesUnknownStepTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Workflow.Workflows

  test "workflows-are-data: criterion 2 a workflow file naming a step the loop has no implementation for is refused, naming the file and the step",
       %{tmp_dir: dir} do
    file = Path.join(dir, "design-pass.json")

    File.write!(
      file,
      Jason.encode!(%{
        "name" => "design-pass",
        "steps" => [
          %{"name" => "run", "actor" => "system"},
          %{"name" => "frobnicate", "actor" => "system"}
        ]
      })
    )

    assert {:error, message} = Workflows.load_dir(dir)
    assert message =~ "design-pass.json"
    assert message =~ "frobnicate"
  end
end
