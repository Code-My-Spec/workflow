defmodule Workflow.Machine do
  @moduledoc """
  The machine the loop runs on, and its one cap on works in flight, whose slots
  every project it runs shares (see notes/the-cap-belongs-to-the-machine.md).

  Each project's loop keeps its works in flight in its own works directory
  (`Workflow.Run.works_dir/0`). At each hand-in it writes itself into the
  machine's directory (`:machine_dir`, by default `~/.workflow/machine`): one
  file per works directory, holding that directory and the project's own cap
  (its config.json's `manager.cap`, default 3). The projects agree on the
  machine's cap by taking the smallest any of them names; the works in flight
  on the machine are every one in each of their works directories. A project
  whose works directory is gone is no longer one of the machine's.

  With `:machine_dir` set to `false` the project is alone: its own cap and its
  own works only, as under test.
  """

  @doc "Where the machine's projects write themselves, or false for a project alone."
  @spec dir() :: String.t() | false
  def dir do
    case Application.get_env(:workflow, :machine_dir) do
      nil -> Path.join([System.user_home!(), ".workflow", "machine"])
      dir -> dir
    end
  end

  @doc """
  Writes this project, with its own `cap`, into the machine, and answers the
  works in flight on the machine and the machine's cap: `{flying, cap}`.
  """
  @spec in_flight(pos_integer()) :: {non_neg_integer(), pos_integer()}
  def in_flight(cap) do
    works = Workflow.Run.works_dir()
    projects = [%{"works_dir" => works, "cap" => cap} | others(works, cap)]

    # Each project's works holding a slot: a parked one holds none (`Workflow.Run.running/1`).
    flying = projects |> Enum.map(&Workflow.Run.running(&1["works_dir"])) |> Enum.sum()

    {flying, projects |> Enum.map(& &1["cap"]) |> Enum.min()}
  end

  @doc "The works directories of the machine's other projects (whose queues it shares)."
  @spec others() :: [String.t()]
  def others do
    case dir() do
      false -> []
      dir -> dir |> listed(Workflow.Run.works_dir()) |> Enum.map(& &1["works_dir"])
    end
  end

  # The machine's other projects, once this one is written in beside them.
  defp others(works, cap) do
    case dir() do
      false ->
        []

      dir ->
        File.mkdir_p!(dir)
        own = %{"works_dir" => works, "cap" => cap}
        File.write!(Path.join(dir, key(works) <> ".json"), Jason.encode!(own))
        listed(dir, works)
    end
  end

  defp listed(dir, works) do
    for file <- Path.wildcard(Path.join(dir, "*.json")),
        {:ok, json} <- [File.read(file)],
        {:ok, %{"works_dir" => "" <> other, "cap" => other_cap}} <- [Jason.decode(json)],
        is_integer(other_cap) and other != works and File.dir?(other),
        do: %{"works_dir" => other, "cap" => other_cap}
  end

  defp key(works),
    do: :sha256 |> :crypto.hash(works) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
