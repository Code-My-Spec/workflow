defmodule Workflow.StaticReview do
  @moduledoc """
  A short section of facts the system works out, put in front of a reviewer
  with its step's note. It is information for the reviewer, never a rule:
  nothing in it blocks, fails or changes any step.
  """

  alias Workflow.Checkout

  @doc "The static review section for `work` at `snapshot`, empty when there is nothing to report."
  @spec section(map(), map()) :: String.t()
  def section(%{"root" => root} = work, snapshot) do
    stat = Checkout.diff_stat(root, snapshot.main)

    [
      what_changed(stat),
      guards(work, stat),
      tests_changed(work, snapshot),
      criteria_met(snapshot)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp what_changed(""), do: ""
  defp what_changed(stat), do: "What changed:\n#{stat}"

  # The paths in a `--stat` listing are read straight off it: no second git call to name them.
  defp guards(work, stat) do
    {guards, suffixes} = guard_list(work)

    case stat |> changed_paths() |> Enum.filter(&guarded?(&1, guards, suffixes)) do
      [] ->
        ""

      paths ->
        "Changes to the test boundary and its guards:\n" <>
          Enum.map_join(paths, "\n", &"- #{&1}") <>
          "\n\nA reviewer should look at each of these, since they are what keep tests honest."
    end
  end

  # The work's own guards, else the plugin's file (`Workflow.Plugin.guards/0`).
  defp guard_list(%{"guards" => [_ | _] = guards}), do: {guards, []}
  defp guard_list(_work), do: Workflow.Plugin.guards()

  defp guarded?(path, guards, suffixes) do
    Enum.any?(guards, &(path == &1 or String.starts_with?(path, &1 <> "/"))) or
      Enum.any?(suffixes, &String.ends_with?(path, &1))
  end

  defp changed_paths(stat) do
    stat
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "|", parts: 2) do
        [path, _rest] -> [String.trim(path)]
        _no_pipe -> []
      end
    end)
  end

  # The results kept for the work, keyed by tree: a tree's "by" result names the
  # agent step that last ended there, with a timestamp Workflow.Run records.
  defp tests_changed(work, snapshot) do
    case most_recent_specify(snapshot) do
      nil ->
        ""

      tree ->
        dir = Path.join(work["project"] || ".", "test")

        case Checkout.diff_stat(work["root"], tree, snapshot.head, dir) do
          "" -> ""
          stat -> "Tests changed after QA last wrote them:\n#{stat}"
        end
    end
  end

  defp most_recent_specify(snapshot) do
    candidates =
      snapshot
      |> Map.get(:results, %{})
      |> Enum.filter(fn {_tree, result} ->
        is_map(result) and get_in(result, ["by", "step"]) == "specify"
      end)

    case candidates do
      [] ->
        nil

      list ->
        list
        |> Enum.max_by(fn {_tree, result} -> get_in(result, ["by", "at"]) || "" end)
        |> elem(0)
    end
  end

  defp criteria_met(snapshot) do
    notes =
      snapshot
      |> Map.get(:results, %{})
      |> Enum.filter(fn {_tree, result} ->
        is_map(result) and get_in(result, ["specify", "status"]) == "pass"
      end)
      |> Enum.map(fn {_tree, result} -> get_in(result, ["specify", "note"]) end)
      |> Enum.filter(&is_binary/1)

    case notes do
      [] -> ""
      notes -> "Criteria QA said were already met:\n" <> Enum.join(notes, "\n")
    end
  end
end
