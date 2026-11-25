defmodule Workflow.WorkflowsAreDataTest do
  use ExUnit.Case, async: true

  alias Workflow.Workflows

  # What a workflow file says of a step: its name, actor and, for an agent's
  # step, the tools it is given.
  defp shape(steps) do
    Enum.map(steps, fn step ->
      {step.name, step.actor, get_in(step, [:agent, :tools])}
    end)
  end

  for {kind, template} <- [
        {"story", Workflow.Story},
        {"issue", Workflow.Issue},
        {"journey", Workflow.Journey}
      ] do
    test "workflows-are-data: criterion 1 the #{kind} workflow is a file that names the steps the code ran" do
      kind = unquote(kind)
      template = unquote(template)

      assert {:ok, %{name: ^kind, steps: steps, file: file} = workflow} = Workflows.load(kind)
      assert File.regular?(file)

      # A file that names a verify ends with it, a system step, run once at the end.
      ran = if workflow[:verify], do: steps ++ [%{name: "verify", actor: :system}], else: steps
      assert shape(ran) == shape(template.steps())

      for %{actor: actor} = step <- steps, actor not in [:system, :owner, :external] do
        assert is_binary(step.agent.brief) and step.agent.brief != ""
      end
    end
  end
end
