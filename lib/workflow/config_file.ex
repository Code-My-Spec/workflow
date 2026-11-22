defmodule Workflow.ConfigFile do
  @moduledoc """
  The service's own settings, read once at boot from a JSON file.

  The file is `config.json` beside the works directory, where the service keeps
  its other files (`inbox/`, `works/`): by default `~/.workflow/config.json`.
  Its top-level keys are the application settings of the same name, taken as
  they are:

    * `"manager"`: the project manager (see `Workflow.Manager`). Work lands in
      the repository's primary checkout (the first line of `git worktree list`),
      on whatever branch it has, even when its `"repo"` names a linked worktree.
    * `"recipients"`: who messages go to and how (see `Workflow.Messages`).
    * `"instructions"`: the path of a text file, the brief given to a chat in the
      answer to MCP `initialize`. Front matter (a block between two `---` lines
      at its start) is dropped. A file that is not there stops the boot. With
      none, a release uses its packaged `instructions.md` (under `RELEASE_ROOT`).
    * `"push"`: `{"remote": ..., "branch": ...}`, where the main copy is pushed
      after a work lands. Each defaults to `"origin"` and `"dev"`. A main copy
      without that remote pushes nothing.
    * `"plugin"`: a Claude Code plugin folder (see `Workflow.Plugin`), absolute
      or read against the manager's `"repo"`. Each agent is given its
      `skills/<role>`. One that names no folder, or a folder with no
      `.claude-plugin/plugin.json`, stops the boot. With none, a release uses
      its packaged `plugin/` (under `RELEASE_ROOT`).
    * `"skills"`, in any agent entry (the manager's `"agent"`, each role under
      its `"agents"`, each recipient): a list of skill folders (see
      `Workflow.Skills`). One without a readable SKILL.md that has a name and a
      description stops the boot, naming it.
    * `"server"`: `{"url": "wss://host/socket/websocket", "project_id": "..."}`
      (and optionally `"state_dir"`): the loop dials out to that server and
      relays its chat to the manager (see `Workflow.Server`). With none, it does not.

  An example:

      {
        "manager": {
          "agent": {"provider": "claude-code"},
          "repo": "/path/to/repo",
          "cap": 3
        },
        "plugin": "plugins/phoenix",
        "recipients": {
          "me": {"kind": "chat"},
          "dev": {"kind": "claude-code", "socket": "/tmp/dev.sock"},
          "other": {"kind": "codex", "thread": "thread-id"}
        }
      }

  With no file the service starts as it would without one. A setting already
  given another way (`-e` code, config) is kept over the file's. A file that is
  not valid JSON stops the boot with a message naming it.
  """

  @keys ["manager", "recipients", "push", "server"]

  @doc "Where the file is read from."
  @spec path() :: String.t()
  def path, do: Path.join(Path.dirname(Workflow.Run.works_dir()), "config.json")

  @doc "Reads the file into the application's settings: `:ok`, or `{:error, message}`."
  @spec load() :: :ok | {:error, String.t()}
  def load do
    file = path()

    case File.read(file) do
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, "cannot read config file #{file}: #{:file.format_error(reason)}"}

      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = settings} ->
            apply_settings(settings)

          {:ok, _other} ->
            {:error, "config file #{file} is not a JSON object"}

          {:error, error} ->
            {:error, "config file #{file} is not valid JSON: #{Exception.message(error)}"}
        end
    end
  end

  defp apply_settings(settings) do
    # Skills named in an agent entry: relative ones are read against the repo the
    # works are cut from, whose checkouts hold the same folders.
    repo = if is_map(settings["manager"]), do: settings["manager"]["repo"]

    root = if is_binary(repo), do: repo, else: File.cwd!()

    with :ok <- plugin(settings["plugin"], root),
         :ok <- Workflow.Skills.check_settings(settings, root) do
      put_settings(settings)
    else
      {:error, why} -> {:error, "config file #{path()}: #{why}"}
    end
  end

  # The plugin, kept as an absolute folder; one that is not a plugin stops the boot.
  # With none named, the running release's packaged one, when it has one.
  defp plugin(nil, root) do
    case packaged("plugin") do
      nil -> :ok
      dir -> plugin(dir, root)
    end
  end

  defp plugin(named, root) do
    with {:ok, dir} <- Workflow.Plugin.check(named, root) do
      if Application.get_env(:workflow, :plugin) == nil,
        do: Application.put_env(:workflow, :plugin, dir)

      :ok
    end
  end

  defp put_settings(settings) do
    for key <- @keys, Map.has_key?(settings, key) do
      atom = String.to_atom(key)

      if Application.get_env(:workflow, atom) == nil,
        do: Application.put_env(:workflow, atom, settings[key])
    end

    instructions(settings["instructions"])
  end

  # The brief a connecting chat is given: the named file's text, without any front matter.
  # With none named, the running release's packaged instructions.md, when it has one.
  defp instructions(nil) do
    case packaged("instructions.md") do
      nil -> :ok
      brief -> instructions(brief)
    end
  end

  defp instructions("" <> brief) do
    if Application.get_env(:workflow, :instructions) != nil do
      :ok
    else
      case File.read(brief) do
        {:ok, text} ->
          Application.put_env(:workflow, :instructions, strip_front_matter(text))
          :ok

        {:error, reason} ->
          {:error,
           "cannot read instructions file #{brief} named in #{path()}: " <>
             "#{:file.format_error(reason)}"}
      end
    end
  end

  defp instructions(_other),
    do: {:error, "config file #{path()}: \"instructions\" must be the path of a file"}

  # What `just package` put at the running release's root (`RELEASE_ROOT`), found
  # at each boot, so it follows the installed version across upgrades.
  defp packaged(name) do
    with "" <> root <- System.get_env("RELEASE_ROOT"),
         path = Path.join(root, name),
         true <- File.exists?(path) do
      path
    else
      _none -> nil
    end
  end

  # A skill's front matter: a block between two `---` lines at the very start.
  defp strip_front_matter(text),
    do: String.replace(text, ~r/\A---[ \t]*\r?\n.*?^---[ \t]*(\r?\n|\z)/ms, "", global: false)
end
