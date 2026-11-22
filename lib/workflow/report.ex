defmodule Workflow.Report do
  @moduledoc """
  The whole current picture of one work, as the loop reports it to the server
  (`Workflow.Server` pushes it as `"report"` on `loop:<project_id>`). Every kind
  reports in one shape; its steps and who acts on each come from the work's own
  template. The loop only sends: nothing is queued, replayed or read back, and a
  report that cannot be made or sent is logged and never stops a step.
  """

  require Logger

  alias Workflow.Checkout

  @doc """
  Hands the report of the work `id` checked out at `root` to the loop's line to
  the server, where there is one. Called by `Workflow.Checkout.record/4` alone.
  """
  @spec recorded(String.t(), String.t()) :: :ok
  def recorded(root, id) do
    # Made in a process of its own: the step never waits on it or fails with it,
    # and `Workflow.Run.look/1` reads the checkout's lock as someone else's.
    if server = Process.whereis(Workflow.Server) do
      Task.start(fn ->
        if report = safely(fn -> of(root, id) end), do: send(server, {:report, report})
      end)
    end

    :ok
  end

  @doc "The report of the work `id` checked out at `root`, or nil where no work was kept there."
  @spec of(String.t(), String.t()) :: map() | nil
  def of(root, id) do
    work = root |> Checkout.kept(id) |> Map.merge(%{"id" => id, "root" => root})

    with "" <> _kind <- work["kind"],
         %{} = seen <- Workflow.Run.look(work) do
      status = status(work, seen)

      report = %{
        "project" => project(),
        "work" => id,
        "kind" => work["kind"],
        "title" => work["title"] || id,
        "steps" => Enum.map(seen.steps, &%{"name" => &1.name, "actor" => to_string(&1.actor)}),
        "step" => seen.step,
        "status" => status,
        "commit" => Checkout.commit(root),
        "at" => Checkout.now(),
        "machine" => machine(),
        "note" => note(seen),
        # Each test (file and test) that failed in ci's first run and passed in its retry.
        "flakes" => get_in(seen.found, ["ci", "flakes"]) || []
      }

      if status == "landed", do: Map.merge(report, landed(work, seen)), else: report
    else
      _none -> nil
    end
  end

  @doc "The report of every work in flight: what is sent each time the line is made or re-made."
  @spec in_flight() :: [map()]
  def in_flight do
    for file <- Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")),
        {:ok, %{"id" => id} = work} <- [file |> File.read!() |> Jason.decode()],
        root = work["root"] || (work["repo"] && Checkout.root(work["repo"], id)),
        is_binary(root) and File.dir?(root),
        report = safely(fn -> of(root, id) end),
        do: report
  end

  @doc """
  A report, status not started, for each journey file under `stories/` in
  `repo` (or a project directory of it) that has no work: sent when the loop
  starts. A file no longer there is not reported.
  """
  @spec unstarted(String.t() | nil) :: [map()]
  def unstarted(repo) when is_binary(repo) do
    flying =
      MapSet.new(
        Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")),
        &Path.basename(&1, ".json")
      )

    commit = Checkout.commit(repo)

    for file <-
          Path.wildcard(Path.join(repo, "stories/*.yml")) ++
            Path.wildcard(Path.join(repo, "*/stories/*.yml")),
        yml = File.read!(file),
        String.match?(yml, ~r/^kind: "?journey"?\s*$/m),
        id = field(yml, "id") || Path.basename(file, ".yml"),
        id not in flying and safely(fn -> Checkout.kept(repo, id) end) == %{} do
      %{
        "project" => project(),
        "work" => id,
        "kind" => "journey",
        "title" => field(yml, "title") || id,
        "steps" =>
          Enum.map(
            Workflow.Journey.steps(),
            &%{"name" => &1.name, "actor" => to_string(&1.actor)}
          ),
        "step" => nil,
        "status" => "not started",
        "commit" => commit,
        "at" => Checkout.now(),
        "machine" => machine(),
        "note" => nil
      }
    end
  end

  def unstarted(_no_repo), do: []

  defp safely(make) do
    make.()
  catch
    kind, why ->
      Logger.warning("[Workflow.Report] no report made: #{Exception.format_banner(kind, why)}")
      nil
  end

  defp field(yml, key) do
    case Regex.run(~r/^#{key}: (.+)$/m, yml) do
      [_, value] ->
        case Jason.decode(value) do
          {:ok, "" <> decoded} -> decoded
          _plain -> String.trim(value)
        end

      nil ->
        nil
    end
  end

  defp status(%{"id" => id, "root" => root} = work, seen) do
    stopped = seen[:stopped]

    cond do
      Checkout.cancelled?(work["repo"] || root, id) ->
        "stopped"

      seen.done ->
        "landed"

      stopped && String.starts_with?(stopped["reason"] || "", "waiting on its owner") ->
        "waiting on a person"

      stopped ->
        "failed"

      seen.actor == :owner ->
        "waiting on a person"

      true ->
        "running"
    end
  end

  # The reviewer's reason or the failure text, one line.
  defp note(seen) do
    text =
      (seen[:stopped] && seen.stopped["reason"]) ||
        Enum.find_value(seen.found, fn
          {_step, %{"status" => status, "note" => "" <> note}}
          when status in ["fail", "failed", "refused", "conflicted", "reject"] ->
            note

          _other ->
            nil
        end)

    if is_binary(text), do: text |> String.split("\n", trim: true) |> List.first()
  end

  # The evidence folder is what the work's demo left, where it ran one.
  defp landed(%{"id" => id, "root" => root} = work, seen) do
    commit =
      case Checkout.outcome(work["repo"] || root, id) do
        %{landed: {commit, _stat}} -> commit
        _none -> nil
      end

    %{"landed" => commit, "evidence" => get_in(seen.found, ["demo", "dir"])}
  end

  defp project, do: (Application.get_env(:workflow, :server) || %{})["project_id"]

  defp machine do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
