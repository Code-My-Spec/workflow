defmodule Workflow.Works do
  @moduledoc """
  A work is a record on the server (`notes/works_contract.md`): made at hand-in,
  claimed by the loop that runs it, updated by every report (`Workflow.Report`
  carries its `work_status`), and read back at the loop's first join, so a loop
  restart loses nothing. All on the line to the server (`Workflow.Server.call/3`).

  The record holds what the work is (`kind`, `id`, its `subject`) and where it
  is (`status`, `step`); how to run it here (repository, project, agents) is the
  loop's own, from its manager's settings. A loop with no line to a server makes
  no record and runs its hand-ins as before.
  """

  require Logger

  alias Workflow.Run

  # How a work is run here, and the loop's own bookkeeping: none of it is the
  # record's subject.
  @local ~w(kind id repo project agents agent root own turn queued review demo note)

  # No line to a server, or one that is not up (Slipstream's push refusals): the
  # hand-in runs here as before, not refused for want of a line.
  @down [:no_server, :not_joined, :not_connected]

  @doc """
  Has the server make the record of `work` as it is handed in, and claims it:
  `{:ok, work}` to run, the work as the record says it; `:local` with no line
  to a server, or one not up; `{:error, why}` when either is refused, and nothing is run.
  """
  @spec hand_in(map()) :: {:ok, map()} | :local | {:error, term()}
  def hand_in(%{"kind" => kind, "id" => id} = work) do
    record = %{"kind" => kind, "id" => id, "workflow" => kind, "subject" => subject(work)}

    case Workflow.Server.call("hand_in", record) do
      {:ok, %{"work" => %{"id" => ^id} = made}} -> claim(made)
      {:error, down} when down in @down -> :local
      other -> refused(id, "hand_in", other)
    end
  end

  @doc """
  Claims the server's `record` for this loop: `{:ok, work}`, the work to run as
  the claimed record says it, or `{:error, why}` when the server refuses.
  """
  @spec claim(map()) :: {:ok, map()} | {:error, term()}
  def claim(%{"id" => id}) do
    case Workflow.Server.call("claim", %{"work" => id}) do
      {:ok, %{"work" => %{"id" => ^id} = record}} -> {:ok, work(record)}
      other -> refused(id, "claim", other)
    end
  end

  @doc "A record the server made and pushed (`\"work\"`): claimed, then run."
  @spec taken(map()) :: :ok
  def taken(record) do
    with {:ok, work} <- claim(record), do: run(work)
    :ok
  end

  @doc """
  Every work this loop has claimed and the server still holds open, run on from
  the step its record shows; one the loop already keeps (in flight or queued)
  is left to it. Asked once, at the line's first join.
  """
  @spec recover() :: :ok
  def recover do
    case Workflow.Server.call("claimed", %{}) do
      {:ok, %{"works" => records}} when is_list(records) ->
        kept = MapSet.new(Run.story_works(), & &1["id"])

        for %{"id" => "" <> id, "status" => status} = record <- records,
            status in ["queued", "running"],
            id not in kept do
          Logger.info("[Workflow #{id}] recovered from its record at #{record["step"] || status}")
          run(work(record))
        end

      other ->
        Logger.warning("[Workflow.Works] claimed works not read: #{inspect(other)}")
    end

    :ok
  end

  # A work queued behind another is queued again; any other is started.
  defp run(%{"behind" => "" <> _} = work), do: Run.queue(work)
  defp run(work), do: Run.start(work)

  # The work a record says, run here with the manager's repository, project and
  # agents, and the agent's turn on the step the record shows given back.
  defp work(%{"kind" => kind, "id" => id} = record) do
    here =
      (Workflow.Manager.configured() || %{})
      |> Map.take(["repo", "project", "agents"])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    work = (record["subject"] || %{}) |> Map.drop(@local) |> Map.merge(here)
    work = Map.merge(work, %{"kind" => kind, "id" => id})

    case record["step"] do
      "" <> step -> Map.put(work, "turn", %{"step" => step, "note" => record["note"]})
      _none -> work
    end
  end

  defp subject(work), do: Map.drop(work, @local)

  defp refused(id, event, answer) do
    Logger.warning("[Workflow #{id}] #{event} refused by the server: #{inspect(answer)}")

    case answer do
      {:error, why} -> {:error, why}
      other -> {:error, other}
    end
  end
end
