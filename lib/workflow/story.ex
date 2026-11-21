defmodule Workflow.Story do
  @moduledoc """
  A story: built one acceptance criterion at a time. QA writes a failing test
  for the next untested criterion (`specify`), the system runs the tests
  (`run`), a coder makes them pass (`work`), the system merges and checks
  (`certify`), a reviewer passes or fails it (`review`), and the system
  merges it into the main copy (`promote`).

  Everything a story shares with a journey is in `Workflow.Parts`. The
  snapshot adds `criteria` (the work's own list) and `named` (the criterion
  numbers already under test) to the checkout's own.
  """

  @behaviour Workflow.Template

  alias Workflow.Parts

  @word "criterion"
  @key :criteria
  @noun "story"

  @impl true
  def steps do
    [
      %{name: "specify", actor: :qa, agent: Parts.qa(@word, @noun)},
      %{name: "run", actor: :system},
      %{name: "work", actor: :coder, agent: Parts.coder(@noun)},
      %{name: "certify", actor: :system},
      %{name: "review", actor: :reviewer, agent: Parts.reviewer(@noun, @key)},
      %{name: "promote", actor: :system}
    ]
  end

  @impl true
  def status(step, snapshot), do: Parts.status(step, snapshot, @word, @key, @noun)

  @impl true
  def perform(name, work, snapshot), do: Parts.perform(name, work, snapshot)

  @impl true
  def observe(work, snapshot) do
    # A story handed in with rules is walked one scenario at a time.
    work = Map.put(work, "criteria", Workflow.StoryFile.criteria(work))
    Parts.observe(@key, @word, work, snapshot)
  end
end
