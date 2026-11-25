defmodule Workflow.Issue do
  @moduledoc """
  An issue: a coder fixes it with a test (`fix`), the system merges the main
  copy's branch and checks the result (`certify`), a reviewer passes or fails it
  (`review`), the system merges it into the main copy (`promote`), and it waits
  on its `ci` event (`ci`).

  Its steps, and each agent's brief and tools, are in its workflow file
  (`priv/workflows/issue.json`).
  The snapshot is `%{head, commits, results}`: the checkout's tree, how many
  commits of its own it has, and what was found at each tree, by step.
  """

  @behaviour Workflow.Template

  @impl true
  def steps, do: Workflow.Workflows.steps!("issue")

  @impl true
  # Merged, the branch has nothing of its own again: that is done, not unstarted.
  def status(%{name: "fix"}, %{commits: 0} = snapshot) do
    if found(snapshot, "promote")["status"] == "promoted",
      do: :done,
      else: %{
        note:
          "Fix the issue. Add a test that fails without your fix, unless the work's text " <>
            "says what the check is. Commit it."
      }
  end

  def status(%{name: "fix"}, _snapshot), do: :done

  def status(%{name: "certify"}, snapshot) do
    case found(snapshot, "certify") do
      %{"status" => "passed"} -> :done
      %{"status" => "failed", "note" => note} -> {:to, "fix", %{note: note}}
      nil -> %{}
    end
  end

  def status(%{name: "review"}, snapshot) do
    case found(snapshot, "review") do
      %{"status" => "pass"} -> :done
      %{"status" => "fail", "note" => note} -> {:to, "fix", %{note: "The review failed: #{note}"}}
      nil -> %{note: "Review the fix against the branch `#{snapshot[:main]}`."}
    end
  end

  def status(%{name: "promote"}, snapshot) do
    case found(snapshot, "promote") do
      %{"status" => "promoted"} -> :done
      %{"status" => "refused", "note" => note} -> {:to, "fix", %{note: note}}
      %{"status" => "conflicted", "note" => note} -> {:to, "fix", %{note: note, stop: true}}
      nil -> %{}
    end
  end

  def status(%{name: "ci"}, snapshot), do: Workflow.Parts.ci(snapshot, "fix")

  @impl true
  def perform("certify", %{"root" => root} = work, snapshot),
    do: Workflow.Checkout.certify(root, snapshot, work["project"], work["id"])

  def perform("promote", %{"root" => root} = work, snapshot),
    do: Workflow.Checkout.promote(root, snapshot, work["id"])

  defp found(%{head: head, results: results}, step), do: get_in(results, [head, step])
end
