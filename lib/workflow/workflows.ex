defmodule Workflow.Workflows do
  @moduledoc """
  The workflow files: each kind of work's steps as data. A workflow file is
  JSON, `priv/workflows/<name>.json`, naming its steps in order, each step's
  actor and, for an agent's step, its agent: its brief and tools (and whether
  it decides). What a step does and how its status is read stay in the loop's
  templates, found by the step's name: a file naming a step the loop has no
  implementation for is refused.
  """

  # The steps the loop has an implementation for.
  @known ~w(specify run work fix certify review demo approve promote ci)

  @doc "The folder the loop's own workflow files are in."
  def dir, do: Application.app_dir(:workflow, "priv/workflows")

  @doc "The names of the steps the loop has an implementation for."
  def known, do: @known

  @doc "The plugin's workflows folder, when the plugin in use has one."
  def plugin_dir do
    with "" <> plugin <- Workflow.Plugin.dir(),
         folder = Path.join(plugin, "workflows"),
         true <- File.dir?(folder) do
      folder
    else
      _none -> nil
    end
  end

  @doc """
  The names of the workflows there are files for: the loop's own and the
  plugin's, which adds new ones or replaces the loop's by name.
  """
  def names do
    [dir(), plugin_dir()]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.json")))
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The workflow named `name`, read from its file: the plugin's, when its
  workflows folder has one by that name, else the loop's own.
  """
  def load(name), do: load_file(file(name))

  defp file(name) do
    own = Path.join(dir(), name <> ".json")

    with "" <> folder <- plugin_dir(),
         plugged = Path.join(folder, name <> ".json"),
         true <- File.regular?(plugged) do
      plugged
    else
      _none -> own
    end
  end

  @doc """
  Every workflow file in `dir`, by name, or the first one refused, with a
  message naming the file and what is wrong with it. No folder (nil) has none.
  """
  def load_dir(nil), do: {:ok, %{}}

  def load_dir(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn file, {:ok, acc} ->
      case load_file(file) do
        {:ok, workflow} -> {:cont, {:ok, Map.put(acc, workflow.name, workflow)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  @doc "The workflow in `file`, or why it is refused, naming the file."
  def load_file(file) do
    with {:ok, body} <- File.read(file),
         {:ok, %{"steps" => [_ | _] = steps} = data} <- Jason.decode(body),
         :ok <- implemented(file, steps),
         :ok <- verify_implemented(file, data["verify"]) do
      name = data["name"] || Path.basename(file, ".json")
      workflow = %{name: name, steps: Enum.map(steps, &step/1), file: file}

      # A verify, when the file names one, runs once at the end over the work's events.
      {:ok, if(data["verify"], do: Map.put(workflow, :verify, data["verify"]), else: workflow)}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "#{file}: #{Exception.message(error)}"}

      {:error, "" <> message} ->
        {:error, message}

      {:error, reason} ->
        {:error, "#{file}: #{:file.format_error(reason)}"}

      {:ok, _data} ->
        {:error, "#{file}: names no steps"}
    end
  end

  @doc """
  The steps of the workflow named `name`, or raises naming its file. One that
  names a verify ends with a system step `verify`, run once at the end; with
  none, the work is done when its last step is.
  """
  def steps!(name) do
    case load(name) do
      {:ok, %{steps: steps, verify: verify}} -> steps ++ [%{name: "verify", actor: :system, verify: verify}]
      {:ok, %{steps: steps}} -> steps
      {:error, message} -> raise ArgumentError, "workflow #{message}"
    end
  end

  defp implemented(file, steps) do
    case Enum.find(steps, &(not (is_map(&1) and &1["name"] in @known))) do
      nil ->
        :ok

      %{"name" => name} ->
        {:error, "#{file}: names the step #{inspect(name)}, which the loop has no implementation for"}

      other ->
        {:error, "#{file}: a step with no name: #{inspect(other)}"}
    end
  end

  defp verify_implemented(_file, nil), do: :ok
  defp verify_implemented(_file, verify) when verify in @known, do: :ok

  defp verify_implemented(file, verify),
    do: {:error, "#{file}: names the verify #{inspect(verify)}, which the loop has no implementation for"}

  defp step(%{"name" => name, "actor" => actor} = step) do
    base = %{name: name, actor: String.to_atom(actor)}

    case step["agent"] do
      nil -> base
      agent -> Map.put(base, :agent, agent(agent))
    end
  end

  defp agent(agent) do
    Map.new(agent, fn
      {"tools", tools} -> {:tools, Enum.map(tools, &String.to_atom/1)}
      {"decides", "may"} -> {:decides, :may}
      {key, value} -> {String.to_atom(key), value}
    end)
  end
end
