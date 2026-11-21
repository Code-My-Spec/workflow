defmodule Workflow.MixProject do
  use Mix.Project

  def project do
    [
      app: :workflow,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: deps(),
      releases: [workflow: [include_executables_for: [:unix]]]
    ]
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
      {:slipstream, "1.2.2"}
    ]
  end
end
