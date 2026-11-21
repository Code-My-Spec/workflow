defmodule Workflow.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Its own settings, from `config.json` beside the works (`Workflow.ConfigFile`).
    case Workflow.ConfigFile.load() do
      :ok ->
        start_tree()

      {:error, message} ->
        require Logger
        Logger.error(message)
        {:error, message}
    end
  end

  defp start_tree do
    # Served only where a port is configured: as a dependency it is a library.
    served =
      case Application.get_env(:workflow, :port) do
        nil -> []
        port -> [{Bandit, plug: Workflow.Router, port: port, ip: {127, 0, 0, 1}}]
      end

    # What each agent on a work has said and done so far (`Workflow.Agents`).
    remembered = %{
      id: Workflow.Agents,
      start: {Agent, :start_link, [fn -> %{} end, [name: Workflow.Agents]]}
    }

    # The project manager's one message at a time (`Workflow.Manager`).
    manager = %{
      id: Workflow.Manager,
      start: {Agent, :start_link, [fn -> nil end, [name: Workflow.Manager]]}
    }

    # Dials out to the server, where `config.json` names one (`Workflow.Server`).
    dialed =
      case Application.get_env(:workflow, :server) do
        %{"url" => "" <> _, "project_id" => "" <> _} = server -> [{Workflow.Server, server}]
        _none -> []
      end

    started =
      Supervisor.start_link([remembered, manager | served] ++ dialed,
        strategy: :one_for_one,
        name: Workflow.Supervisor
      )

    # A service that went down left its works in flight: they carry on.
    if served != [], do: Task.start(&Workflow.Run.resume/0)
    started
  end
end
