defmodule Workflow.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # erl puts the release's own erts/bin first on PATH; children must use the project's.
    System.put_env("PATH", without_release_erts(System.get_env("PATH", ""), System.get_env("BINDIR")))
    check_path(System.get_env("PATH", ""))

    # Its own settings, from `config.json` beside the works (`Workflow.ConfigFile`).
    # Its workflow files, each naming only steps it has an implementation for
    # (`Workflow.Workflows`).
    with :ok <- Workflow.ConfigFile.load(),
         {:ok, _workflows} <- Workflow.Workflows.load_dir(Workflow.Workflows.dir()),
         {:ok, _plugged} <- Workflow.Workflows.load_dir(Workflow.Workflows.plugin_dir()) do
      start_tree()
    else
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

  @doc "`path` without the release's own erts `bindir` entry."
  def without_release_erts(path, nil), do: path

  def without_release_erts(path, bindir),
    do: path |> String.split(":") |> Enum.reject(&(&1 == bindir)) |> Enum.join(":")

  defp start_tree do
    # Served only where a port is configured: as a dependency it is a library.
    # Only to a Host of 127.0.0.1 or localhost (`Workflow.LocalOnly`).
    served =
      case Application.get_env(:workflow, :port) do
        nil -> []
        port -> [{Bandit, plug: Workflow.LocalOnly, port: port, ip: {127, 0, 0, 1}}]
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
    # Each `"servers"` entry gets a line of its own beside it.
    dialed =
      case Application.get_env(:workflow, :server) do
        %{"url" => "" <> _, "project_id" => "" <> _} = server -> [{Workflow.Server, server}]
        _none -> []
      end ++
        for {%{"url" => "" <> _, "project_id" => "" <> _} = server, n} <-
              Enum.with_index(Application.get_env(:workflow, :servers) || [], 1) do
          Supervisor.child_spec({Workflow.Server, {server, Workflow.Server.name(n)}},
            id: Workflow.Server.name(n)
          )
        end

    # Served, it looks now and then for a free slot, which another project's loop
    # may have freed, for its queue (`Workflow.Run.next_in_slot/0`).
    ticking =
      if served != [],
        do: [%{id: :queue_tick, start: {Task, :start_link, [&tick/0]}}],
        else: []

    started =
      Supervisor.start_link([remembered, manager | served] ++ dialed ++ ticking,
        strategy: :one_for_one,
        name: Workflow.Supervisor
      )

    # A service that went down left its works in flight: they carry on.
    if served != [], do: Task.start(&Workflow.Run.resume/0)
    started
  end

  defp tick do
    Process.sleep(5_000)

    try do
      Workflow.Run.next_in_slot()
    catch
      kind, why ->
        require Logger
        Logger.warning("[Workflow] no slot filled: #{Exception.format_banner(kind, why)}")
    end

    tick()
  end
end
