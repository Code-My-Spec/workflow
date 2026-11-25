defmodule Workflow do
  @moduledoc """
  Which step a piece of work is on: a pure function of a template and a
  snapshot of facts. Nothing is stored and nothing is read, so the harness and
  the server reach the same answer from the same snapshot.

  A template (`Workflow.Template`) lists its steps in order, each with an
  actor, and says what one step needs given the snapshot. The current step is
  the first not done; nil means the work is finished. What a snapshot holds and
  what it means is the template's alone.
  """

  @type step :: %{
          required(:name) => String.t(),
          required(:actor) => atom(),
          required(:note) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc "The step the snapshot puts the work on, or nil once every step is done."
  @spec current(Workflow.Template.t(), term()) :: step() | nil
  def current(template, snapshot) do
    steps = Workflow.Template.steps(template)

    Enum.find_value(steps, fn step ->
      case Workflow.Template.status(template, step, snapshot) do
        :done ->
          nil

        {:to, name, needs} ->
          case Enum.find(steps, &(&1.name == name)) do
            nil -> raise ArgumentError, "unknown step #{inspect(name)}"
            target -> step(target, needs)
          end

        needs ->
          step(step, needs)
      end
    end)
  end

  # `agent` is the template's own word on who does the step: carried, never read.
  defp step(definition, needs),
    do:
      %{note: nil} |> Map.merge(Map.take(definition, [:name, :actor, :agent])) |> Map.merge(needs)

  @doc "The role a step may wake: its actor, unless that is the system, the owner or an event."
  @spec wakes(step() | nil) :: atom() | nil
  def wakes(%{actor: actor}) when actor not in [:system, :owner, :external], do: actor
  def wakes(_step), do: nil
end
