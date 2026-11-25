defmodule Workflow.Template do
  @moduledoc """
  One kind of work: its steps in the order they are settled, and what each
  needs given a snapshot.

  `status/2` answers `:done`, a map of what the step needs (at least a `note`
  when an agent or a person is to act), or `{:to, name, needs}` to hand the work
  to another step.
  """

  @type step :: %{
          required(:name) => String.t(),
          required(:actor) => atom(),
          optional(atom()) => term()
        }
  @type status :: :done | map() | {:to, String.t(), map()}

  @callback steps() :: [step()]
  @callback status(step(), snapshot :: term()) :: status()

  @doc "Does a system step of the work, and answers what it found."
  @callback perform(step_name :: String.t(), work :: map(), snapshot :: map()) :: map()

  @doc "What the template reads beyond the checkout's own snapshot."
  @callback observe(work :: map(), snapshot :: map()) :: map()

  @optional_callbacks perform: 3, observe: 2

  @typedoc """
  A template module, or `{module, kind}`: a kind of work from a workflow file
  with no module of its own, its steps read from that file and what each does
  and how its status is read found by the step's name in `module`.
  """
  @type t :: module() | {module(), String.t()}

  @doc "The steps of `template`, in order."
  @spec steps(t()) :: [step()]
  def steps({_module, kind}), do: Workflow.Workflows.steps!(kind)
  def steps(module), do: module.steps()

  @doc "What `step` needs given `snapshot`."
  @spec status(t(), step(), term()) :: status()
  def status({module, _kind}, step, snapshot), do: module.status(step, snapshot)
  def status(module, step, snapshot), do: module.status(step, snapshot)

  @doc "Does the system step `name` of `work`."
  @spec perform(t(), String.t(), map(), map()) :: map()
  def perform({module, _kind}, name, work, snapshot), do: module.perform(name, work, snapshot)
  def perform(module, name, work, snapshot), do: module.perform(name, work, snapshot)

  @doc "What `template` reads beyond the checkout's own snapshot, or nothing."
  @spec observe(t(), map(), map()) :: map()
  def observe({module, _kind}, work, snapshot), do: observe(module, work, snapshot)

  def observe(module, work, snapshot) do
    # Loaded first: a module nothing has called yet exports nothing.
    if Code.ensure_loaded?(module) and function_exported?(module, :observe, 2),
      do: module.observe(work, snapshot),
      else: %{}
  end
end
