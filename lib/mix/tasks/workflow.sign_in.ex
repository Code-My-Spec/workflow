defmodule Mix.Tasks.Workflow.SignIn do
  @moduledoc """
  Signs the loop in to the server `config.json` names, by the device grant
  (`Workflow.SignIn`), the same as the release's `workflow sign-in`.

      mix workflow.sign_in
  """
  @shortdoc "Signs the loop in to its server"

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    Workflow.SignIn.main()
  end
end
