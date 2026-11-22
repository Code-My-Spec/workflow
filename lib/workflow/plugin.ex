defmodule Workflow.Plugin do
  @moduledoc """
  The plugin the loop runs with: one Claude Code plugin folder, named by
  `"plugin"` in the config file. It has `.claude-plugin/plugin.json` at its root
  and `skills/<role>/SKILL.md` under it; each agent the loop runs is given its
  role's folder, when there is one. A `.mcp.json` at its root gives each Claude
  Code agent its MCP servers. A plain file `guards` at its root lists the
  paths a reviewer is shown changes to (see `Workflow.StaticReview`).

  All the loop knows of a language is in the plugin.
  """

  @doc "The plugin folder in use, absolute, or nil with none."
  @spec dir() :: String.t() | nil
  def dir, do: Application.get_env(:workflow, :plugin)

  @doc """
  The plugin named by `path`, read against `repo` when relative: `{:ok,
  absolute folder}`, or `{:error, why}` when it names no folder or one with no
  `.claude-plugin/plugin.json`.
  """
  @spec check(term(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def check("" <> path, repo) do
    dir = Path.expand(path, repo)

    cond do
      not File.dir?(dir) ->
        {:error, "plugin #{path} names no folder"}

      not File.regular?(manifest(dir)) ->
        {:error, "plugin #{path} has no .claude-plugin/plugin.json"}

      true ->
        {:ok, dir}
    end
  end

  def check(other, _repo),
    do: {:error, "plugin must be the path of a folder, not #{inspect(other)}"}

  defp manifest(dir), do: Path.join([dir, ".claude-plugin", "plugin.json"])

  @doc "The skill folders the plugin gives `role`: its `skills/<role>`, when there is one."
  @spec skills(atom() | String.t()) :: [String.t()]
  def skills(role) do
    with "" <> dir <- dir(),
         folder = Path.join([dir, "skills", to_string(role)]),
         true <- File.dir?(folder) do
      [folder]
    else
      _none -> []
    end
  end

  @doc "The plugin's `.mcp.json`, the MCP servers each Claude Code agent is given; nil with none."
  @spec mcp() :: String.t() | nil
  def mcp do
    with "" <> dir <- dir(),
         path = Path.join(dir, ".mcp.json"),
         true <- File.regular?(path) do
      path
    else
      _none -> nil
    end
  end

  @doc """
  The guards in the plugin's `guards` file, one per line (blank lines and `#`
  lines skipped): `{paths, suffixes}`, a line starting with `*` being a suffix.
  None with no file.
  """
  @spec guards() :: {[String.t()], [String.t()]}
  def guards do
    with "" <> dir <- dir(),
         {:ok, text} <- File.read(Path.join(dir, "guards")) do
      lines =
        text
        |> String.split(~r/\r?\n/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

      {suffixes, paths} = Enum.split_with(lines, &String.starts_with?(&1, "*"))
      {paths, Enum.map(suffixes, &String.trim_leading(&1, "*"))}
    else
      _none -> {[], []}
    end
  end
end
