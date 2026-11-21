defmodule Mix.Tasks.Workflow.Init do
  @moduledoc """
  Writes a new user's `config.json` (`Workflow.Init`), the same as the
  release's `workflow init`.

      mix workflow.init [--repo PATH] [--plugin DIR] [--server URL --project ID]
  """
  @shortdoc "Writes the loop's config.json"

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    Workflow.Init.main(args)
  end
end
