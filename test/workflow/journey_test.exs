defmodule Workflow.JourneyTest do
  use ExUnit.Case, async: true

  alias Workflow.Journey

  # The journey at tree "h" with `stages`, the stage numbers already `named`,
  # and what was found at "h".
  defp current(stages, named, found) do
    Workflow.current(Journey, %{
      id: "j1",
      head: "h",
      main: "trunk",
      stages: stages,
      named: named,
      results: %{"h" => found}
    })
  end

  test "no stage is named yet, so qa writes the first, quoting its text" do
    assert %{name: "specify", actor: :qa, agent: %{tools: tools}, note: note, stage: 1} =
             current(["the user signs up", "the user signs in"], [], %{})

    assert :edit in tools
    assert note =~ "the user signs up"
    assert note =~ "j1: stage 1"
  end

  test "the steps run in order, with the owner's approve between review and promote" do
    assert Enum.map(Journey.steps(), & &1.name) == [
             "specify",
             "run",
             "work",
             "certify",
             "review",
             "demo",
             "approve",
             "promote"
           ]

    assert Enum.find(Journey.steps(), &(&1.name == "approve")) == %{
             name: "approve",
             actor: :owner
           }
  end

  test "certified and reviewed, the owner is asked to decide on the demo" do
    found = %{
      "run" => %{"status" => "passed"},
      "certify" => %{"status" => "passed"},
      "review" => %{"status" => "pass"},
      "demo" => %{"status" => "passed"}
    }

    assert %{name: "approve", actor: :owner, note: note} =
             current(["the user signs up"], [1], found)

    assert note =~ "demo"
  end

  test "the owner approves the demo, and the journey moves on to promote" do
    found = %{
      "run" => %{"status" => "passed"},
      "certify" => %{"status" => "passed"},
      "review" => %{"status" => "pass"},
      "demo" => %{"status" => "passed"},
      "approve" => %{"status" => "approve"}
    }

    assert %{name: "promote", actor: :system} = current(["the user signs up"], [1], found)
  end

  test "met-needs-a-test: criterion 1 - a stage already met with no new commit goes back to qa for the test" do
    found = %{
      "run" => %{"status" => "passed"},
      "by" => %{"step" => "specify"},
      "specify" => %{"status" => "pass", "note" => "already met"}
    }

    assert %{name: "specify", actor: :qa, note: note} =
             Workflow.current(Journey, %{
               id: "j1",
               head: "h",
               main: "trunk",
               stages: ["a"],
               named: [1],
               commits: 0,
               results: %{"h" => found}
             })

    assert note =~ "test"
  end

  test "met-needs-a-test: criterion 2 - a stage already met with no new commit stays on that stage, not met" do
    found = %{
      "run" => %{"status" => "passed"},
      "by" => %{"step" => "specify"},
      "specify" => %{"status" => "pass", "note" => "already met"}
    }

    snapshot = %{
      id: "j1",
      head: "h",
      main: "trunk",
      stages: ["a", "b"],
      named: [1],
      commits: 0,
      results: %{"h" => found}
    }

    assert %{name: "specify", actor: :qa, stage: 1, note: note} =
             Workflow.current(Journey, snapshot)

    assert note =~ "j1: stage 1"

    committed = %{snapshot | commits: 1}
    assert %{name: "specify", stage: 2} = Workflow.current(Journey, committed)
  end

  test "a stage already met with no new commit, on a branch with earlier commits, goes back to qa" do
    # Two commits on the branch before qa's turn on stage 2, and still two after.
    found = %{
      "run" => %{"status" => "passed"},
      "by" => %{"step" => "specify", "from" => 2},
      "specify" => %{"status" => "pass", "note" => "already met"}
    }

    snapshot = %{
      id: "j1",
      head: "h",
      main: "trunk",
      stages: ["a", "b"],
      named: [1, 2],
      commits: 2,
      results: %{"h" => found}
    }

    assert %{name: "specify", actor: :qa, stage: 2, note: note} =
             Workflow.current(Journey, snapshot)

    assert note =~ "j1: stage 2"

    # The turn made a commit: the test is there, and it passed.
    committed = %{snapshot | commits: 3}
    assert %{name: "certify"} = Workflow.current(Journey, committed)
  end

  test "met-needs-a-test: criterion 3 - a stage not called already met must still have a failing test" do
    snapshot = fn found, commits ->
      %{
        id: "j1",
        head: "h",
        main: "trunk",
        stages: ["a", "b"],
        named: [1],
        commits: commits,
        results: %{"h" => found}
      }
    end

    # Green fresh off specify, and qa did not call it met: rewrite, commit or not.
    green = %{"run" => %{"status" => "passed"}, "by" => %{"step" => "specify"}}

    for commits <- [0, 1] do
      assert %{name: "specify", actor: :qa, stage: 1, note: note} =
               Workflow.current(Journey, snapshot.(green, commits))

      assert note =~ "passes already"
    end

    # A failing test is what the loop wants: on to the coder.
    red = %{
      "run" => %{"status" => "failed", "note" => "1 failure"},
      "by" => %{"step" => "specify"}
    }

    assert %{name: "work", actor: :coder} = Workflow.current(Journey, snapshot.(red, 1))
  end

  test "the owner rejects the demo, and the work goes back to the coder with the note" do
    found = %{
      "run" => %{"status" => "passed"},
      "certify" => %{"status" => "passed"},
      "review" => %{"status" => "pass"},
      "demo" => %{"status" => "passed"},
      "approve" => %{"status" => "reject", "note" => "the demo skipped a step"}
    }

    assert %{name: "work", note: "the demo skipped a step"} =
             current(["the user signs up"], [1], found)
  end

  test "rejection-reaches-the-coder: criterion 3 - a rejection the coder has not answered does not wait on the owner again" do
    passed = %{
      "run" => %{"status" => "passed"},
      "certify" => %{"status" => "passed"},
      "review" => %{"status" => "pass"},
      "demo" => %{"status" => "passed"}
    }

    # Rejected at "h"; the tree has since moved to "h2", where all has passed again.
    snapshot = %{
      id: "j1",
      head: "h2",
      main: "trunk",
      stages: ["the user signs up"],
      named: [1],
      results: %{
        "h" => Map.put(passed, "approve", %{"status" => "reject", "note" => "skipped a step"}),
        "h2" => passed,
        "rejected" => "skipped a step"
      }
    }

    assert %{name: "work", actor: :coder, note: "skipped a step"} =
             Workflow.current(Journey, snapshot)

    answered = %{snapshot | results: Map.delete(snapshot.results, "rejected")}
    assert %{name: "approve", actor: :owner} = Workflow.current(Journey, answered)
  end
end
