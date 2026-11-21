defmodule Workflow.Issue do
  @moduledoc """
  An issue: a coder fixes it with a test (`fix`), the system merges the main
  copy's branch and checks the result (`certify`), a reviewer passes or fails it
  (`review`) and the system merges it into the main copy (`promote`).

  Each agent's step says what kind of agent does it: its brief and its tools.
  The snapshot is `%{head, commits, results}`: the checkout's tree, how many
  commits of its own it has, and what was found at each tree, by step.
  """

  @behaviour Workflow.Template

  @coder %{
    tools: [:read, :edit, :write, :bash],
    brief:
      "You are the coder on one issue in this checkout. Fix what you are told, with a " <>
        "test that fails without your fix, commit it with git, then end your turn."
  }

  @reviewer %{
    tools: [:read, :bash],
    decides: true,
    brief:
      "You review one fix in this checkout, and change nothing. Read the diff since the " <>
        "branch you are told (`git diff <branch>...HEAD`). Does it fix what was asked, does " <>
        "its test fail without the fix, is it lean? Then call `decide` once: pass, or fail " <>
        "with a note saying what must change."
  }

  @steps [
    %{name: "fix", actor: :coder, agent: @coder},
    %{name: "certify", actor: :system},
    %{name: "review", actor: :reviewer, agent: @reviewer},
    %{name: "promote", actor: :system}
  ]

  @impl true
  def steps, do: @steps

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
      %{"status" => "promoted"} -> Workflow.Parts.landed(snapshot, "fix")
      %{"status" => "refused", "note" => note} -> {:to, "fix", %{note: note}}
      %{"status" => "conflicted", "note" => note} -> {:to, "fix", %{note: note, stop: true}}
      nil -> %{}
    end
  end

  @impl true
  def perform("certify", %{"root" => root} = work, snapshot),
    do: Workflow.Checkout.certify(root, snapshot, work["project"])

  def perform("promote", %{"root" => root}, snapshot),
    do: Workflow.Checkout.promote(root, snapshot)

  defp found(%{head: head, results: results}, step), do: get_in(results, [head, step])
end
