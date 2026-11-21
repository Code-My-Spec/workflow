defmodule Workflow.Provision do
  @moduledoc """
  A provision: the system runs each step named in the project's `provision/steps`,
  or `provision/<target>.steps` for a work naming a target (then run with
  PROVISION_TARGET=<target>), one a line, in order, as `just provision <step> <dir>`, reading its SARIF as
  certify's is (`provision`). Every one passing, the work is done, or with a fix
  committed, goes on to certify, review and promote as an issue does. One failing
  hands the work to a coder (`fix`) with what failed. A project with no
  `provision/steps` stops the work.
  """

  @behaviour Workflow.Template

  @coder %{
    tools: [:read, :edit, :write, :bash],
    brief:
      "You are the coder on one provision in this checkout. Make the failing step of the " <>
        "project's `just provision` recipe pass, keep no credentials in it, commit it with " <>
        "git, then end your turn."
  }

  # A fix the coder committed is certified, reviewed and promoted as an issue's is.
  @impl true
  def steps do
    [
      %{name: "go", actor: :owner},
      %{name: "provision", actor: :system},
      %{name: "fix", actor: :coder, agent: @coder}
    ] ++ tl(Workflow.Issue.steps())
  end

  @impl true
  def observe(%{"target" => "prod", "root" => root}, _snapshot),
    do: %{target: "prod", since: Workflow.Checkout.since_deployed(root)}

  def observe(work, _snapshot), do: %{target: work["target"]}

  # Prod is provisioned only on the owner's go, given for the tree it would deploy.
  @impl true
  def status(%{name: "go"}, %{target: "prod", head: head, results: results} = snapshot) do
    note = "Waiting on the owner's go to deploy tree #{head} to prod."

    cond do
      get_in(results, [head, "go"]) ->
        :done

      snapshot[:since] ->
        %{note: note <> " Commits since the last prod provision that passed:\n" <> snapshot.since}

      true ->
        %{note: note}
    end
  end

  def status(%{name: "go"}, _snapshot), do: :done

  def status(%{name: "provision"}, %{head: head, results: results}) do
    case get_in(results, [head, "provision"]) do
      %{"status" => "passed"} -> :done
      %{"status" => "failed", "note" => note} -> {:to, "fix", %{note: note}}
      %{"status" => "stopped", "note" => note} -> {:to, "fix", %{note: note, stop: true}}
      nil -> %{}
    end
  end

  # Reached only when provisioning failed; a commit makes a new tree, provisioned again.
  def status(%{name: "fix"}, _snapshot), do: :done

  # Nothing committed on the branch: there is no fix to certify, review or promote.
  def status(_step, %{commits: 0}), do: :done
  def status(step, snapshot), do: Workflow.Issue.status(step, snapshot)

  @impl true
  def perform(step, work, snapshot) when step in ["certify", "promote"],
    do: Workflow.Issue.perform(step, work, snapshot)

  def perform("provision", %{"root" => root} = work, _snapshot) do
    target = work["target"]
    file = if target, do: "provision/#{target}.steps", else: "provision/steps"
    env = if target, do: [{"PROVISION_TARGET", target}], else: []
    result = provisioned(root, work["project"], file, env)
    if target == "prod" and result["status"] == "passed", do: Workflow.Checkout.deployed(root)
    result
  end

  defp provisioned(root, project, file, env) do
    case File.read(Path.join([root, project || ".", file])) do
      {:ok, steps} ->
        steps
        |> String.split("\n", trim: true)
        |> Enum.reduce_while(%{"status" => "passed"}, fn step, passed ->
          case Workflow.Checkout.analyse(root, project, ["provision", step], env) do
            %{"status" => "passed"} -> {:cont, passed}
            failed -> {:halt, Map.update(failed, "note", step, &"#{step}: #{redacted(&1)}")}
          end
        end)

      {:error, _none} ->
        %{
          "status" => "stopped",
          "note" => "there is no #{file} naming the `just provision` steps"
        }
    end
  end

  # A recipe sees the service's environment, and what it prints is kept and handed to
  # agents, so no value of that environment is.
  # shortcut: values under 8 characters are left, since replacing them would mangle notes; name the secrets if one is shorter.
  defp redacted(note) do
    System.get_env()
    |> Map.values()
    |> Enum.filter(&(byte_size(&1) >= 8))
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(note, &String.replace(&2, &1, "[redacted]"))
  end
end
