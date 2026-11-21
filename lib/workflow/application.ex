defmodule Workflow.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    check_path(System.get_env("PATH", ""))

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

  @needed [
    {"claude", "no agent turn can run"},
    {"git", "no work can be checked out or landed"},
    {"just", "a project's checks and commands can't run"}
  ]

  @doc """
  Logs one line for each of `claude`, `git` and `just` not found on `path`,
  saying how the loop fails without it. Returns `:ok` either way.
  """
  def check_path(path) do
    require Logger

    for {program, without} <- @needed,
        :os.find_executable(String.to_charlist(program), String.to_charlist(path)) == false do
      Logger.warning("[Workflow] `#{program}` is not on PATH: without it, #{without}")
    end

    :ok
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
