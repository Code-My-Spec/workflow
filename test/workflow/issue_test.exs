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

  test "passed, the system promotes; merged, it waits on ci, and green it is done and not back at the start" do
    passed = %{"certify" => %{"status" => "passed"}, "review" => %{"status" => "pass"}}
    assert %{name: "promote", actor: :system} = current(1, passed)
    promoted = Map.put(passed, "promote", %{"status" => "promoted"})
    assert %{name: "ci", actor: :external} = current(0, promoted)
    assert current(0, Map.put(promoted, "ci", %{"verdict" => "green"})) == nil
    assert current(0, Map.put(promoted, "ci", %{"verdict" => "flaky"})) == nil
  end

  test "loop-waits-on-evidence: criterion 5 - ci red sends it back to the coder at fix with the failing tests" do
    promoted = %{
      "certify" => %{"status" => "passed"},
      "review" => %{"status" => "pass"},
      "promote" => %{"status" => "promoted"},
      "ci" => %{
        "verdict" => "red",
        "tree" => "abc1234",
        "commit" => "c9",
        "failing" => ["test/a_test.exs:12", "test/b_test.exs:3"]
      }
    }

    assert %{name: "fix", actor: :coder, note: note} = current(0, promoted)
    assert note =~ "test/a_test.exs:12"
    assert note =~ "test/b_test.exs:3"
    assert note =~ "c9"
  end
end
