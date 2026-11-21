defmodule Workflow.IssueTest do
  use ExUnit.Case, async: true

  alias Workflow.Issue

  # The issue at tree "h" with `commits` of its own and what was found there.
  defp current(commits, found),
    do:
      Workflow.current(Issue, %{
        head: "h",
        main: "trunk",
        commits: commits,
        results: %{"h" => found}
      })

  test "a coder fixes it first, and is the template's kind of agent" do
    assert %{name: "fix", actor: :coder, agent: %{tools: tools}} = current(0, %{})
    assert :edit in tools
    assert %{name: "certify", actor: :system} = current(1, %{})
  end

  test "a coder fixing it is told to add a failing test, unless the work's own text says what the check is" do
    assert %{name: "fix", note: note} = current(0, %{})
    assert note =~ "unless the work's text"
  end

  test "a failed check goes back to the coder with what failed" do
    failed = %{"certify" => %{"status" => "failed", "note" => "`mix test` failed"}}
    assert %{name: "fix", note: "`mix test` failed"} = current(1, failed)
  end

  test "certified, a reviewer decides; a fail goes back to the coder" do
    certified = %{"certify" => %{"status" => "passed"}}

    assert %{name: "review", actor: :reviewer, agent: %{decides: true}, note: note} =
             current(1, certified)

    assert note =~ "trunk"

    failed = Map.put(certified, "review", %{"status" => "fail", "note" => "no test"})
    assert %{name: "fix", note: "The review failed: no test"} = current(1, failed)
  end

  test "passed, the system promotes; merged, it is done and not back at the start" do
    passed = %{"certify" => %{"status" => "passed"}, "review" => %{"status" => "pass"}}
    assert %{name: "promote", actor: :system} = current(1, passed)
    assert current(0, Map.put(passed, "promote", %{"status" => "promoted"})) == nil
  end
end
