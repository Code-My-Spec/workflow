defmodule Workflow.Journey do
  @moduledoc """
  A journey: built one stage at a time. QA writes a failing test for the next
  untested stage (`specify`), the system runs the tests (`run`), a coder
  makes them pass (`work`), the system merges and checks (`certify`), a
  reviewer passes or fails it (`review`), the system runs the project's
  `just demo` (`demo`), the owner decides on the demo (`approve`), and the system merges it into the main copy (`promote`), then
  waits on its `ci` event. Approve waits on an event named "approve" as `ci` does.

  Everything a journey shares with a story is in `Workflow.Parts`. The
  snapshot adds `stages` (the work's own list) and `named` (the stage
  numbers already under test) to the checkout's own.
  """

  @behaviour Workflow.Template

  alias Workflow.Parts

  @word "stage"
  @key :stages
  @noun "journey"

  @impl true
  def steps do
    [
      %{name: "specify", actor: :qa, agent: Parts.qa(@word, @noun)},
      %{name: "run", actor: :system},
      %{name: "work", actor: :coder, agent: Parts.coder(@noun)},
      %{name: "certify", actor: :system},
      %{name: "review", actor: :reviewer, agent: Parts.reviewer(@noun, @key)},
      %{name: "demo", actor: :system},
      %{name: "approve", actor: :owner},
      %{name: "promote", actor: :system},
      Parts.ci_step()
    ]
  end

  # An owner's rejection the coder has not had a turn with yet is kept under no
  # tree (`results["rejected"]`): it goes with whatever sends the work to the
  # coder, and any step for another agent or the owner is the coder's instead,
  # so the owner is not asked the same decision again before the coder answers.
  @impl true
  def status(step, snapshot) do
    case get_in(snapshot, [:results, "rejected"]) do
      nil -> walk(step, snapshot)
      note -> owed(walk(step, snapshot), step, note)
    end
  end

  defp owed(:done, _step, _note), do: :done
  defp owed({:to, "work", needs}, _step, note), do: {:to, "work", told(needs, note)}
  defp owed(needs, %{name: "work"}, note), do: told(needs, note)
  defp owed(needs, %{actor: :system}, _note), do: needs
  # Another agent's or the owner's step: what it would say is not the coder's.
  defp owed(_needs, _step, note), do: {:to, "work", %{note: note}}

  defp told(needs, note) do
    case needs[:note] do
      said when said in [nil, ""] -> Map.put(needs, :note, note)
      said -> if said =~ note, do: needs, else: Map.put(needs, :note, rejected(said, note))
    end
  end

  defp rejected(said, note), do: said <> "\n\nThe owner rejected the demo: " <> note

  defp walk(%{name: "ci"}, snapshot), do: Parts.ci(snapshot, "work")

  # Done once an "approve" event is recorded, unless it rejects.
  defp walk(%{name: "approve"}, snapshot) do
    case Parts.found(snapshot, "approve") do
      %{"status" => "reject", "note" => note} ->
        {:to, "work", %{note: note}}

      %{} ->
        :done

      nil ->
        if snapshot[:approved],
          do: :done,
          else: %{note: "Waiting on the owner's decision on the demo. " <> demo(snapshot)}
    end
  end

  # A failed demo goes back to the coder with its output, as a failed certify does.
  defp walk(%{name: "demo"}, snapshot) do
    case Parts.found(snapshot, "demo") do
      %{"status" => "failed", "note" => note} -> {:to, "work", %{note: note}}
      nil -> %{}
      _passed_or_none -> :done
    end
  end

  defp walk(step, snapshot), do: Parts.status(step, snapshot, @word, @key, @noun)

  @impl true
  def perform("demo", %{"root" => root} = work, _snapshot),
    do: Workflow.Checkout.demo(root, work["project"])

  def perform(name, work, snapshot), do: Parts.perform(name, work, snapshot)

  @impl true
  def observe(work, snapshot) do
    dir = get_in(snapshot, [:results, snapshot[:head], "demo", "dir"])

    @key
    |> Parts.observe(@word, work, snapshot)
    |> Map.merge(%{
      checkout: Path.join(work["root"], work["project"] || "."),
      demo_files: files(dir),
      approved: approved?(work, snapshot)
    })
  end

  # An approval kept at an earlier tree still counts when no path changed since
  # is one of the work's own changes against main: only main's merge came in.
  defp approved?(%{"root" => root}, %{head: head, main: main, results: results} = snapshot)
       when is_binary(main) do
    is_nil(Parts.found(snapshot, "approve")) and
      Enum.any?(results, fn
        {tree, %{"approve" => %{} = approve}} when tree != head ->
          approve["status"] != "reject" and
            Workflow.Checkout.only_main_since?(root, tree, main)

        _other ->
          false
      end)
  end

  defp approved?(_work, _snapshot), do: false

  defp files(nil), do: []

  defp files(dir),
    do:
      dir |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1) |> Enum.sort()

  # Where the owner sees the demo: what `just demo` left, or, with no recipe, the checkout.
  defp demo(snapshot) do
    case {Parts.found(snapshot, "demo"), snapshot[:demo_files] || []} do
      {%{"status" => "none"}, _files} ->
        "The project has no `demo` recipe, so none was made: the work is in " <>
          "`#{snapshot[:checkout]}`, on branch `journey/#{snapshot.id}`."

      {found, []} ->
        "`just demo` left nothing in `#{found["dir"]}`."

      {_found, files} ->
        "`just demo` left: " <> Enum.map_join(files, ", ", &"`#{&1}`") <> "."
    end
  end
end
