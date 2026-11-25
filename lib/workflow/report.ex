defmodule Workflow.Report do
  @moduledoc """
  The whole current picture of one work, as the loop reports it to the server
  (`Workflow.Server` pushes it as `"report"` on `loop:<project_id>`). Every kind
  reports in one shape; its steps and who acts on each come from the work's own
  template. Its `work` names the work's server record, which `step`, `note` and
  `work_status` update (`notes/works_contract.md`). The loop only sends: nothing is read back, and a report that cannot
  be made is logged and never stops a step. One that cannot be sent is kept,
  the newest a work, and sent at the next join (see `Workflow.Server`).
  A work's last report is `ended/3`'s.
  """

  require Logger

  alias Workflow.Checkout

  @doc """
  Hands the report of the work `id` checked out at `root` to the loop's line to
  the server, where there is one. Called by `Workflow.Checkout.record/4` (a
  step's result, an event) and by `Workflow.Run` (a hand-in, entering a step,
  a wait on the owner), so every change of a work's step or status is sent.
  """
  @spec recorded(String.t(), String.t()) :: :ok
  def recorded(root, id) do
    # Made in a process of its own, so a report never fails the step, and
    # `Workflow.Run.look/1` reads the checkout's lock as someone else's. Waited
    # on, as `ended/3` waits: reports leave in the order the work changed, so
    # the newest picture is the last, and none comes after a work's last report.
    if (lines = Workflow.Server.lines()) != [] do
      task = Task.async(fn -> safely(fn -> of(root, id) end) end)

      with {:ok, %{} = report} <- Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill),
           do: for(line <- lines, do: send(line, {:report, report}))
    end

    :ok
  end

  @doc """
  Hands the last report of `work` to the loop's line to the server as the work
  ends, where there is a line: its `status` "done", "stopped" or "released",
  and `step` the step it ended at (where nil, the step it is on; a work done
  ended at its last). A work stopped while it waits on its ci event has landed:
  it is released. Made before this answers, so it is sent before the work's
  file is removed. Called by `Workflow.Run` alone, once as each work ends.
  """
  @spec ended(map(), String.t(), String.t() | nil) :: :ok
  def ended(%{"id" => id} = work, status, step) do
    if (lines = Workflow.Server.lines()) != [] do
      # A work done whose copy is taken away is read from the repository it was
      # cut from, which shares the copy's results.
      root =
        Enum.find(
          [work["root"], work["repo"] && Checkout.root(work["repo"], id), work["repo"]],
          &(is_binary(&1) and File.dir?(&1))
        )

      # Made in a process of its own, as `recorded/2` makes one, but waited on.
      task = Task.async(fn -> root && safely(fn -> of(root, id) end) end)

      with {:ok, %{} = report} <- Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
        step =
          step ||
            if status == "done",
              do: List.last(report["steps"])["name"],
              else: report["step"]

        status = if status == "stopped" and step == "ci", do: "released", else: status

        report = %{
          report
          | "status" => status,
            "step" => step,
            "work_status" => work_status(status)
        }

        for line <- lines, do: send(line, {:report, report})
      end
    end

    :ok
  end

  @doc """
  Hands the report of `work`, queued with no slot free (`Workflow.Run.enqueue/1`),
  to the loop's line to the server, where there is one: status "queued", on no
  step yet, holding no slot.
  """
  @spec queued(map()) :: :ok
  def queued(%{"id" => id} = work) do
    if (lines = Workflow.Server.lines()) != [] do
      report = %{
        "project" => project(),
        "work" => id,
        "kind" => work["kind"],
        "title" => work["title"] || id,
        "steps" => [],
        "step" => nil,
        "status" => "queued",
        "work_status" => "queued",
        "parked" => false,
        "commit" => nil,
        "at" => Checkout.now(),
        "machine" => machine(),
        "note" => nil
      }

      for line <- lines, do: send(line, {:report, report})
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
        "step" => turn(id) || seen.step,
        "status" => status,
        # Waiting on a person or on ci: it holds no slot.
        "parked" =>
          status == "waiting on a person" or (status == "running" and seen.actor == :external),
        "work_status" => work_status(status),
        "commit" => Checkout.commit(root),
        "at" => Checkout.now(),
        "machine" => machine(),
        "note" => note(seen)
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
  A report, status not started, for each journey file under
  `.code_my_spec/stories/` (else `stories/`) in
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

    # `.code_my_spec/stories/` first: an id there is not read again from `stories/`.
    for file <-
          Enum.flat_map(
            ~w(.code_my_spec/stories/*.yml */.code_my_spec/stories/*.yml stories/*.yml */stories/*.yml),
            &Path.wildcard(Path.join(repo, &1))
          )
          |> Enum.uniq_by(&{project_of(repo, &1), Path.basename(&1)}),
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
        "work_status" => work_status("not started"),
        "commit" => commit,
        "at" => Checkout.now(),
        "machine" => machine(),
        "note" => nil
      }
    end
  end

  def unstarted(_no_repo), do: []

  # The project directory a story file is in, nil at the repository's top.
  defp project_of(repo, file) do
    case file |> Path.relative_to(repo) |> Path.split() do
      [top | _] when top in [".code_my_spec", "stories"] -> nil
      [project | _] -> project
    end
  end

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

  # The step of the agent's turn the work is in, as kept in flight
  # (`Workflow.Run`): a turn given back after a restart is on the step its record
  # showed, though the checkout's results, read afresh, would put it earlier.
  defp turn(id) do
    with {:ok, json} <- File.read(Path.join(Workflow.Run.works_dir(), "#{id}.json")),
         {:ok, %{"turn" => %{"step" => "" <> step}}} <- Jason.decode(json),
         do: step,
         else: (_none -> nil)
  end

  # The status the report writes onto the work's server record
  # (`notes/works_contract.md`): queued, running, parked, done or stopped.
  defp work_status("not started"), do: "queued"
  defp work_status("running"), do: "running"
  defp work_status("waiting on a person"), do: "parked"
  defp work_status(status) when status in ["landed", "done"], do: "done"
  defp work_status(_stopped_failed_or_released), do: "stopped"

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
