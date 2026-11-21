defmodule Workflow.Skills do
  @moduledoc """
  An agent's skills: folders named under `"skills"` in its settings entry, and by
  role on a work handed in. A folder holding a SKILL.md is one skill; a folder of
  such folders is all of them. A relative folder is read against the work's
  checkout; an absolute one is used as it is.

  Nothing of a skill is copied: the agent's brief names each one (its name, its
  description, the path to its SKILL.md) and the agent reads the file itself.
  """

  @doc """
  The skills in `folders`, read against `root`: `{:ok, skills}`, or `{:error,
  message}` naming the first folder with no readable SKILL.md that has a name
  and a description.
  """
  @spec find(term(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def find(nil, _root), do: {:ok, []}

  def find(folders, root) when is_list(folders) do
    Enum.reduce_while(folders, {:ok, []}, fn folder, {:ok, found} ->
      case folder(folder, root) do
        {:ok, skills} -> {:cont, {:ok, found ++ skills}}
        error -> {:halt, error}
      end
    end)
  end

  def find(other, _root), do: {:error, "skills must be a list of folders, not #{inspect(other)}"}

  defp folder("" <> folder, root) do
    dir = Path.expand(folder, root)

    refused =
      {:error, "skill folder #{folder} has no readable SKILL.md with a name and a description"}

    if File.regular?(Path.join(dir, "SKILL.md")) do
      case skill(dir) do
        {:ok, skill} -> {:ok, [skill]}
        :error -> refused
      end
    else
      inner =
        case File.ls(dir) do
          {:ok, names} ->
            names
            |> Enum.sort()
            |> Enum.map(&Path.join(dir, &1))
            |> Enum.filter(&File.regular?(Path.join(&1, "SKILL.md")))

          {:error, _reason} ->
            []
        end

      skills = Enum.map(inner, &skill/1)

      if inner != [] and Enum.all?(skills, &match?({:ok, _}, &1)),
        do: {:ok, Enum.map(skills, fn {:ok, skill} -> skill end)},
        else: refused
    end
  end

  defp folder(other, _root),
    do: {:error, "skill folder #{inspect(other)} is not the path of a folder"}

  # The front matter's name and description, read by hand: `key: value` lines
  # between two `---` lines at the very start.
  defp skill(dir) do
    path = Path.join(dir, "SKILL.md")

    with {:ok, text} <- File.read(path),
         [_, block] <- Regex.run(~r/\A---[ \t]*\r?\n(.*?)^---[ \t]*$/ms, text),
         fields = front_matter(block),
         %{"name" => "" <> name, "description" => "" <> description}
         when name != "" and description != "" <- fields do
      {:ok, %{name: name, description: description, path: path}}
    else
      _ -> :error
    end
  end

  defp front_matter(block) do
    for line <- String.split(block, ~r/\r?\n/),
        [_, key, value] <- [Regex.run(~r/\A([A-Za-z_-]+):[ \t]*(.*)\z/, line)],
        into: %{},
        do: {key, value |> String.trim() |> unquote_value()}
  end

  defp unquote_value("\"" <> _ = value), do: String.trim(value, "\"")
  defp unquote_value("'" <> _ = value), do: String.trim(value, "'")
  defp unquote_value(value), do: value

  @doc "What ends an agent's brief for `skills`: a line each and one sentence; empty for none."
  @spec brief([map()]) :: String.t()
  def brief([]), do: ""

  def brief(skills) do
    lines = Enum.map(skills, &"- #{&1.name}: #{&1.description} (#{&1.path})")

    Enum.join(
      ["\n\nYour skills:" | lines] ++
        ["Before doing work a skill's description covers, read its SKILL.md at the path given."],
      "\n"
    )
  end

  @doc """
  Every skill folder named in the settings file (the manager's agent, each role
  under its agents, each recipient), read against `root`: `:ok` or the first error.
  """
  @spec check_settings(map(), String.t()) :: :ok | {:error, String.t()}
  def check_settings(settings, root) do
    manager = if is_map(settings["manager"]), do: settings["manager"], else: %{}

    entries =
      [manager["agent"]] ++ values(manager["agents"]) ++ values(settings["recipients"])

    Enum.find_value(entries, :ok, fn
      %{"skills" => folders} ->
        case find(folders, root) do
          {:ok, _skills} -> nil
          error -> error
        end

      _none ->
        nil
    end)
  end

  defp values(%{} = map), do: Map.values(map)
  defp values(_none), do: []
end
