defmodule Workflow.Sarif do
  @moduledoc """
  An analysis directory: the SARIF files a recipe leaves in it, the meta.json beside them that every writer merges its own part into,
  and the verdict read off both.
  """

  @doc "Reads `dir`'s meta.json, or an empty map outside one."
  @spec meta(String.t()) :: map()
  def meta(dir) do
    with {:ok, json} <- File.read(Path.join(dir, "meta.json")),
         {:ok, %{} = meta} <- Jason.decode(json) do
      meta
    else
      _none -> %{}
    end
  end

  @doc "Merges `fields` into `dir`'s meta.json, keeping what else is there."
  @spec merge_meta(String.t(), map()) :: map()
  def merge_meta(dir, fields) do
    merged =
      dir
      |> meta()
      |> Map.put_new("tree", Path.basename(dir))
      |> deep_merge(fields)

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "meta.json"), Jason.encode!(merged))
    merged
  end

  @doc """
  A new run folder in the tree's analysis directory `tree_dir`, named for the unix
  time it is made (the next free second, so two runs never share one). Not made yet.
  """
  @spec new_run(String.t()) :: String.t()
  def new_run(tree_dir) do
    System.os_time(:second)
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&Path.join(tree_dir, Integer.to_string(&1)))
    |> Enum.find(&(not File.exists?(&1)))
  end

  @doc """
  The latest run of `recipe` in the tree's analysis directory `tree_dir`, as
  `{run folder, its meta}`, or nil when it has none, or its latest was set aside
  to run afresh.
  """
  @spec latest(String.t(), String.t()) :: {String.t(), map()} | nil
  def latest(tree_dir, recipe) do
    found =
      tree_dir
      |> runs()
      |> Enum.find_value(fn run ->
        meta = meta(run)
        if meta["recipe"] == recipe, do: {run, meta}
      end)

    case found do
      {_run, %{"afresh" => true}} -> nil
      found -> found
    end
  end

  # The run folders in `tree_dir`, latest first.
  defp runs(tree_dir) do
    case File.ls(tree_dir) do
      {:ok, names} ->
        names
        |> Enum.flat_map(fn name ->
          case Integer.parse(name) do
            {at, ""} -> [{at, Path.join(tree_dir, name)}]
            _other -> []
          end
        end)
        |> Enum.sort(:desc)
        |> Enum.map(&elem(&1, 1))

      _none ->
        []
    end
  end

  defp deep_merge(a, b) do
    Map.merge(a, b, fn _key, av, bv ->
      if is_map(av) and is_map(bv), do: Map.merge(av, bv), else: bv
    end)
  end

  @doc """
  The verdict from every `*.sarif` file in `dir`: failed with the failing results'
  messages when any result is an error, failed with `output` when `status` is
  non-zero and none is, passed otherwise. Carries `dir` either way.
  """
  @spec verdict(String.t(), non_neg_integer(), String.t()) :: map()
  def verdict(dir, status \\ 0, output \\ "") do
    failures = dir |> Path.join("*.sarif") |> Path.wildcard() |> Enum.flat_map(&errors/1)

    cond do
      failures != [] ->
        note = failures |> Enum.map_join("\n", &message/1) |> String.slice(0, 3000)
        %{"status" => "failed", "note" => note, "dir" => dir}

      status != 0 ->
        %{"status" => "failed", "note" => String.slice(output, -4000, 4000), "dir" => dir}

      true ->
        %{"status" => "passed", "dir" => dir}
    end
  end

  defp errors(file) do
    %{"runs" => runs} = file |> File.read!() |> Jason.decode!()

    for run <- runs,
        name = get_in(run, ["tool", "driver", "name"]),
        result <- Map.get(run, "results", []),
        result["level"] == "error",
        do: {name, result}
  end

  defp message({name, result}), do: "#{name}: #{result["message"]["text"]}#{location(result)}"

  defp location(%{"locations" => [%{"physicalLocation" => phys} | _]}) do
    case {get_in(phys, ["artifactLocation", "uri"]), get_in(phys, ["region", "startLine"])} do
      {file, line} when is_binary(file) and is_integer(line) -> " (#{file}:#{line})"
      _incomplete -> ""
    end
  end

  defp location(_no_location), do: ""
end
