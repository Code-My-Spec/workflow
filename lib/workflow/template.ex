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
end
