defmodule Workflow.Knowledge do
  @moduledoc """
  The framework's own knowledge, shipped under the package's priv directory so
  it is on disk after `mix deps.get` and an agent opens it with the ordinary
  read tool.
  """

  @doc "Where the knowledge files live, wherever the package is installed."
  @spec dir() :: String.t()
  def dir, do: Application.app_dir(:workflow, "priv/knowledge")

  @doc "Every knowledge file, by its path relative to `dir/0`, sorted."
  @spec list() :: [String.t()]
  def list do
    dir()
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir()))
    |> Enum.sort()
  end
end
