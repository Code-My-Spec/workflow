defmodule Workflow.Init do
  @moduledoc """
  Writes a new user's `config.json` (`Workflow.ConfigFile.path/0`), once.

  `workflow init` (the release) or `mix workflow.init` takes:

    * `--repo PATH`: the git checkout the manager works in (default: the
      current directory);
    * `--plugin DIR`: a Claude Code plugin folder, holding
      `.claude-plugin/plugin.json` (optional);
    * `--server URL` and `--project ID`: the server the loop dials and its
      project, both or neither.

  The file names a manager on claude-code for the repo, the coder, reviewer
  and qa agents on claude-code with no model, a chat recipient `"me"`, and
  the plugin and server only when given. An existing file is never
  overwritten, and a bad flag writes nothing.
  """

  @flags [repo: :string, plugin: :string, server: :string, project: :string]

  @doc "Runs init with `args`, printing the outcome; halts with status 1 on an error."
  @spec main([String.t()]) :: :ok
  def main(args \\ release_args()) do
    case run(args, File.cwd!()) do
      {:ok, said} ->
        IO.puts(said)

      {:error, why} ->
        IO.puts(:stderr, "Init failed: #{why}")
        System.halt(1)
    end
  end

  @doc """
  Validates `args` (read against `cwd`) and writes the file: `{:ok, what to
  print}`, or `{:error, why}` with nothing written.
  """
  @spec run([String.t()], String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, cwd) do
    file = Workflow.ConfigFile.path()

    with {:ok, opts} <- parse(args),
         {:ok, repo} <- repo(Path.expand(opts[:repo] || cwd, cwd)),
         {:ok, plugin} <- plugin(opts[:plugin], cwd, repo),
         {:ok, server} <- server(opts[:server], opts[:project]),
         :ok <- absent(file) do
      config =
        %{
          "manager" => %{
            "agent" => claude(),
            "repo" => repo,
            "agents" => %{"coder" => claude(), "reviewer" => claude(), "qa" => claude()}
          },
          "recipients" => %{"me" => %{"kind" => "chat"}}
        }
        |> put("plugin", plugin)
        |> put("server", server)

      json = Jason.encode!(config, pretty: true)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, json <> "\n")

      steps =
        if(server, do: ["workflow sign-in"], else: []) ++
          ["brew services start codemyspec-loop"]

      {:ok,
       "Wrote #{file}:\n\n#{json}\n\nNext:\n\n" <> Enum.map_join(steps, "\n", &("    " <> &1))}
    end
  end

  # The release passes its arguments in WORKFLOW_INIT_ARGS, one per line (rel/env.sh.eex).
  defp release_args do
    case System.get_env("WORKFLOW_INIT_ARGS", "") do
      "" -> []
      lines -> String.split(lines, "\n")
    end
  end

  defp claude, do: %{"provider" => "claude-code"}

  defp put(config, _key, nil), do: config
  defp put(config, key, value), do: Map.put(config, key, value)

  defp parse(args) do
    case OptionParser.parse(args, strict: @flags) do
      {opts, [], []} ->
        {:ok, opts}

      {_opts, _rest, [{flag, _} | _]} ->
        {:error, "#{flag} is not a flag init takes, or wants a value"}

      {_opts, [extra | _], []} ->
        {:error, "#{extra} is not a flag init takes"}
    end
  end

  defp repo(dir) do
    case File.dir?(dir) &&
           System.cmd("git", ["-C", dir, "rev-parse", "--is-inside-work-tree"],
             stderr_to_stdout: true
           ) do
      {"true" <> _, 0} -> {:ok, dir}
      _not -> {:error, "--repo #{dir} is not a git checkout"}
    end
  end

  defp plugin(nil, _cwd, _repo), do: {:ok, nil}

  defp plugin(dir, cwd, repo) do
    case Workflow.Plugin.check(Path.expand(dir, cwd), repo) do
      {:ok, dir} -> {:ok, dir}
      {:error, why} -> {:error, "--plugin: #{why}"}
    end
  end

  defp server(nil, nil), do: {:ok, nil}
  defp server(url, nil), do: {:error, "--server #{url} wants --project with it"}
  defp server(nil, _project), do: {:error, "--project wants --server with it"}
  defp server(url, project), do: {:ok, %{"url" => url, "project_id" => project}}

  defp absent(file) do
    if File.exists?(file),
      do: {:error, "#{file} already exists; init leaves it as it is"},
      else: :ok
  end
end
