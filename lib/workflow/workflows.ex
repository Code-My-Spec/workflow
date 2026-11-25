defmodule Workflow.Workflows do
  @moduledoc """
  The workflow files: each kind of work's steps as data. A workflow file is
  JSON, `priv/workflows/<name>.json`, naming its steps in order, each step's
  actor and, for an agent's step, its agent: its brief and tools (and whether
  it decides). What a step does and how its status is read stay in the loop's
  templates, found by the step's name.
  """

  @doc "The folder the loop's own workflow files are in."
  def dir, do: Application.app_dir(:workflow, "priv/workflows")

  @doc "The workflow named `name`, read from its file."
  def load(name) do
    file = Path.join(dir(), name <> ".json")

    with {:ok, body} <- File.read(file),
         {:ok, %{"steps" => [_ | _] = steps} = data} <- Jason.decode(body) do
      {:ok, %{name: data["name"] || name, steps: Enum.map(steps, &step/1), file: file}}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "#{file}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "#{file}: #{:file.format_error(reason)}"}

      {:ok, _data} ->
        {:error, "#{file}: names no steps"}
    end
  end

  @doc "The steps of the workflow named `name`, or raises naming its file."
  def steps!(name) do
    case load(name) do
      {:ok, %{steps: steps}} -> steps
      {:error, message} -> raise ArgumentError, "workflow #{message}"
    end
  end

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
