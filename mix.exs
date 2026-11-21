defmodule Workflow.MixProject do
  use Mix.Project

  @fallback_version "0.1.0"

  def project do
    version = version_from(git_describe())
    drop_stale_app(version)

    [
      app: :workflow,
      version: version,
      elixir: "~> 1.20",
      deps: deps(),
      releases: [workflow: [include_executables_for: [:unix]]]
    ]
  end

  # The version is the tag the build stands at (v3.0.0 gives 3.0.0), or the
  # fallback where there is no git, no tag, or a tag that is not a version.
  def fallback_version, do: @fallback_version

  def version_from({described, 0}) do
    version = described |> String.trim() |> String.trim_leading("v")

    case Version.parse(version) do
      {:ok, _} -> version
      :error -> @fallback_version
    end
  end

  def version_from(_), do: @fallback_version

  # Mix rewrites a built workflow.app only when mix.exs or the config changes,
  # not when a new commit moves the version, so one built at another version
  # is removed here and Mix writes it again with this one.
  defp drop_stale_app(version) do
    build =
      System.get_env("MIX_BUILD_PATH") || Path.join([__DIR__, "_build", to_string(Mix.env())])

    app = Path.join([build, "lib", "workflow", "ebin", "workflow.app"])

    case :file.consult(app) do
      {:ok, [{:application, :workflow, props}]} ->
        if props[:vsn] != to_charlist(version), do: File.rm(app)

      _none ->
        :ok
    end
  end

  defp git_describe do
    System.cmd("git", ["describe", "--tags"], cd: __DIR__, stderr_to_stdout: true)
  rescue
    _ -> :error
  end

  def application, do: [mod: {Workflow.Application, []}, extra_applications: [:logger]]

  # Nothing from the app this sits in. Alloy runs the agents; Bandit serves the
  # one call that hands the work in.
  defp deps do
    [
      {:alloy,
       git: "https://github.com/Code-My-Spec/alloy.git", branch: "windows-spawn", override: true},
      {:alloy_claude_code,
       git: "https://github.com/Code-My-Spec/alloy_claude_code.git", branch: "windows-spawn"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.2"},
      {:req, "~> 0.5"},
      {:slipstream, "1.2.2"}
    ]
  end
end
