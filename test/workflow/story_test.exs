defmodule Workflow.StoryTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Workflow.Story

  # The story at tree "h" with `criteria`, the criterion numbers already `named`,
  # and what was found at "h".
  defp current(criteria, named, found) do
    Workflow.current(Story, %{
      id: "s1",
      head: "h",
      main: "trunk",
      criteria: criteria,
      named: named,
      results: %{"h" => found}
    })
  end

  test "no criterion is named yet, so qa writes the first, quoting its text" do
    assert %{name: "specify", actor: :qa, agent: %{tools: tools}, note: note, stage: 1} =
             current(["the user logs in", "the user logs out"], [], %{})

    assert :edit in tools
    assert note =~ "the user logs in"
    assert note =~ "s1: criterion 1"
  end

  test "a test fresh off specify that already passes must be rewritten" do
    found = %{"run" => %{"status" => "passed"}, "by" => %{"step" => "specify"}}

    assert %{name: "specify", note: note, stage: 1} =
             current(["the user logs in", "the user logs out"], [1], found)

    assert note =~ "criterion 1"
  end

  test "qa may say the code already meets the criterion, commit its test, and the story moves on" do
    found = %{
      "run" => %{"status" => "passed"},
      "by" => %{"step" => "specify", "from" => 0},
      "specify" => %{"status" => "pass", "note" => "criterion 1's code covers it"}
    }

    committed = fn criteria ->
      Workflow.current(Story, %{
        id: "s1",
        head: "h",
        main: "trunk",
        criteria: criteria,
        named: [1],
        commits: 1,
        results: %{"h" => found}
      })
    end

    assert %{name: "specify", stage: 2} = committed.(["a", "b"])
    assert %{name: "certify"} = committed.(["a"])
  end

  test "a passed run with a criterion still unwritten sends qa to the next" do
    found = %{"run" => %{"status" => "passed"}, "by" => %{"step" => "work"}}

    assert %{name: "specify", note: note, stage: 2} =
             current(["the user logs in", "the user logs out"], [1], found)

    assert note =~ "the user logs out"
    assert note =~ "s1: criterion 2"
  end

  test "an empty criteria list leaves nothing left to name" do
    found = %{"run" => %{"status" => "passed"}, "by" => %{"step" => "work"}}

    assert %{name: "certify", actor: :system} = current([], [1], found)
  end

  test "the system runs the tests once every criterion has one" do
    assert %{name: "run", actor: :system} = current(["the user logs in"], [1], %{})
  end

  test "once every criterion is named and the run passes, the system certifies" do
    found = %{"run" => %{"status" => "passed"}, "by" => %{"step" => "work"}}
    assert %{name: "certify", actor: :system} = current(["the user logs in"], [1], found)
  end

  test "a failed run sends the coder its own output" do
    found = %{"run" => %{"status" => "failed", "note" => "1 test, 1 failure"}}
    assert %{name: "work", actor: :coder, note: note} = current(["the user logs in"], [1], found)
    assert note =~ "1 test, 1 failure"
  end

  test "a failed check goes back to work with what failed" do
    found = %{
      "run" => %{"status" => "passed"},
      "certify" => %{"status" => "failed", "note" => "`mix test` failed"}
    }

    assert %{name: "work", note: "`mix test` failed"} = current(["the user logs in"], [1], found)
  end

  test "certified, a reviewer decides; a fail goes back to work" do
    certified = %{"run" => %{"status" => "passed"}, "certify" => %{"status" => "passed"}}

    assert %{name: "review", actor: :reviewer, agent: %{decides: true}, note: note} =
             current(["the user logs in"], [1], certified)

    assert note =~ "trunk"

    failed = Map.put(certified, "review", %{"status" => "fail", "note" => "no test"})

    assert %{name: "work", note: "The review failed: no test"} =
             current(["the user logs in"], [1], failed)
  end

  test "passed, the system promotes; promoted, it waits on ci: green it is done, red back to work" do
    passed = %{
      "run" => %{"status" => "passed"},
      "certify" => %{"status" => "passed"},
      "review" => %{"status" => "pass"}
    }

    assert %{name: "promote", actor: :system} = current(["the user logs in"], [1], passed)

    promoted = Map.put(passed, "promote", %{"status" => "promoted"})
    assert %{name: "ci", actor: :external} = current(["the user logs in"], [1], promoted)

    assert current(["the user logs in"], [1], Map.put(promoted, "ci", %{"verdict" => "green"})) ==
             nil

    red = %{"verdict" => "red", "failing" => ["test/login_test.exs:4"]}

    assert %{name: "work", actor: :coder, note: note} =
             current(["the user logs in"], [1], Map.put(promoted, "ci", red))

    assert note =~ "test/login_test.exs:4"
  end

  test "met-needs-a-test: criterion 1 - already met with no new commit goes back to qa for the test" do
    found = %{
      "run" => %{"status" => "passed"},
      "by" => %{"step" => "specify"},
      "specify" => %{"status" => "pass", "note" => "already met"}
    }

    assert %{name: "specify", actor: :qa, note: note} =
             Workflow.current(Story, %{
               id: "s1",
               head: "h",
               main: "trunk",
               criteria: ["a"],
               named: [1],
               commits: 0,
               results: %{"h" => found}
             })

    assert note =~ "test"
  end

  test "met-needs-a-test: criterion 2 - already met with no new commit stays on that criterion, not met" do
    found = %{
      "run" => %{"status" => "passed"},
      "by" => %{"step" => "specify"},
      "specify" => %{"status" => "pass", "note" => "already met"}
    }

    snapshot = %{
      id: "s1",
      head: "h",
      main: "trunk",
      criteria: ["a", "b"],
      named: [1],
      commits: 0,
      results: %{"h" => found}
    }

    assert %{name: "specify", actor: :qa, stage: 1, note: note} =
             Workflow.current(Story, snapshot)

    assert note =~ "s1: criterion 1"

    committed = %{snapshot | commits: 1}
    assert %{name: "specify", stage: 2} = Workflow.current(Story, committed)
  end

  test "already met with no new commit, on a branch with earlier commits, goes back to qa" do
    # Two commits on the branch before qa's turn on criterion 2, and still two after.
    found = fn commits_before ->
      %{
        "run" => %{"status" => "passed"},
        "by" => %{"step" => "specify", "from" => commits_before},
        "specify" => %{"status" => "pass", "note" => "already met"}
      }
    end

    snapshot = %{
      id: "s1",
      head: "h",
      main: "trunk",
      criteria: ["a", "b"],
      named: [1, 2],
      commits: 2,
      results: %{"h" => found.(2)}
    }

    assert %{name: "specify", actor: :qa, stage: 2, note: note} =
             Workflow.current(Story, snapshot)

    assert note =~ "s1: criterion 2"

    # The turn made a commit: the test is there, and it passed.
    committed = %{snapshot | commits: 3}
    assert %{name: "certify"} = Workflow.current(Story, committed)
  end

  test "met-needs-a-test: criterion 3 - a criterion not called already met must still have a failing test" do
    snapshot = fn found, commits ->
      %{
        id: "s1",
        head: "h",
        main: "trunk",
        criteria: ["a", "b"],
        named: [1],
        commits: commits,
        results: %{"h" => found}
      }
    end

    # Green fresh off specify, and qa did not call it met: rewrite, commit or not.
    green = %{"run" => %{"status" => "passed"}, "by" => %{"step" => "specify"}}

    for commits <- [0, 1] do
      assert %{name: "specify", actor: :qa, stage: 1, note: note} =
               Workflow.current(Story, snapshot.(green, commits))

      assert note =~ "passes already"
    end

    # A failing test is what the loop wants: on to the coder.
    red = %{
      "run" => %{"status" => "failed", "note" => "1 failure"},
      "by" => %{"step" => "specify"}
    }

    assert %{name: "work", actor: :coder} = Workflow.current(Story, snapshot.(red, 1))
  end

  test "story-shape: criterion 2 - the work's criteria are its scenarios in order, each its rule and the scenario text, walked one at a time",
       %{tmp_dir: dir} do
    work = %{
      "id" => "s1",
      "root" => dir,
      "project" => "myproj",
      "rules" => [
        %{
          "rule" => "Only an owner may invite.",
          "scenarios" => [
            %{"happy" => "An owner invites by email and the invite is sent."},
            %{"fails" => "A member tries to invite and is told only owners can."}
          ]
        },
        %{
          "rule" => "An invite expires.",
          "scenarios" => [%{"happy" => "An invite older than a week is refused."}]
        }
      ]
    }

    criteria = [
      "Only an owner may invite. An owner invites by email and the invite is sent.",
      "Only an owner may invite. A member tries to invite and is told only owners can.",
      "An invite expires. An invite older than a week is refused."
    ]

    assert %{criteria: ^criteria, named: [], id: "s1"} = observed = Story.observe(work, %{})

    assert %{name: "specify", stage: 1, note: first} =
             Workflow.current(Story, observed_snapshot(observed))

    assert first =~ "s1: criterion 1"
    assert first =~ "An owner invites by email and the invite is sent."

    assert %{name: "specify", stage: 2, note: second} =
             Workflow.current(Story, observed_snapshot(%{observed | named: [1]}, passed: true))

    assert second =~ "s1: criterion 2"
    assert second =~ "A member tries to invite and is told only owners can."
  end

  defp observed_snapshot(observed, opts \\ []) do
    found =
      if opts[:passed],
        do: %{"run" => %{"status" => "passed"}, "by" => %{"step" => "work"}},
        else: %{}

    Map.merge(observed, %{head: "h", main: "trunk", results: %{"h" => found}})
  end

  test "observe reads the criterion numbers straight off the test files", %{tmp_dir: dir} do
    test_dir = Path.join([dir, "myproj", "test"])
    File.mkdir_p!(test_dir)

    File.write!(
      Path.join(test_dir, "story_test.exs"),
      "test \"w1: criterion 2 lets the user out\" do\nend\n"
    )

    work = %{
      "id" => "w1",
      "root" => dir,
      "project" => "myproj",
      "criteria" => ["in", "out", "over"]
    }

    assert Story.observe(work, %{}) == %{criteria: ["in", "out", "over"], named: [2], id: "w1"}
  end

  test "a criterion marked for another work's id is not counted", %{tmp_dir: dir} do
    test_dir = Path.join([dir, "myproj", "test"])
    File.mkdir_p!(test_dir)

    File.write!(
      Path.join(test_dir, "story_test.exs"),
      "test \"w2: criterion 1 lets the user in\" do\nend\n"
    )

    work = %{"id" => "w1", "root" => dir, "project" => "myproj", "criteria" => ["in"]}

    assert Story.observe(work, %{}) == %{criteria: ["in"], named: [], id: "w1"}
  end

  test "the bare words \"criterion N\" with no id are not counted", %{tmp_dir: dir} do
    test_dir = Path.join([dir, "myproj", "test"])
    File.mkdir_p!(test_dir)

    File.write!(
      Path.join(test_dir, "story_test.exs"),
      "test \"criterion 1 lets the user in\" do\nend\n"
    )

    work = %{"id" => "w1", "root" => dir, "project" => "myproj", "criteria" => ["in"]}

    assert Story.observe(work, %{}) == %{criteria: ["in"], named: [], id: "w1"}
  end
end
