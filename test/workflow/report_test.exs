defmodule Workflow.ReportTest do
  # The test process stands in for the loop's line to the server: registered
  # under its name, it gets each `{:report, report}` the server would push.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Workflow.Checkout

  setup %{tmp_dir: dir} do
    was =
      for key <- [:server, :manager, :works_dir], do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was,
          do:
            if(value == nil,
              do: Application.delete_env(:workflow, key),
              else: Application.put_env(:workflow, key, value)
            )
    end)

    Application.put_env(:workflow, :server, %{"url" => "ws://x", "project_id" => "p1"})
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.delete_env(:workflow, :manager)
    %{main: repo_with(Path.join(dir, "main"), [{"README", "hi"}])}
  end

  defp repo_with(main, files) do
    git = fn args -> {_, 0} = System.cmd("git", args, cd: main, stderr_to_stdout: true) end
    File.mkdir_p!(main)

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(main, path)))
      File.write!(Path.join(main, path), content)
    end

    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.name", "t"])
    git.(["config", "user.email", "t@example.com"])
    git.(["add", "-A"])
    git.(["commit", "-q", "--allow-empty", "-m", "first"])
    main
  end

  defp stand_in, do: Process.register(self(), Workflow.Server)

  defp issue(main) do
    work = %{"kind" => "issue", "id" => "i1", "root" => main, "title" => "Fix the thing"}
    Checkout.keep(main, "i1", work)
    work
  end

  defp head(main) do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: main)
    String.trim(sha)
  end

  test "loop-reports-to-server: a recorded step result sends one report with the whole picture",
       %{main: main} do
    issue(main)
    stand_in()

    Checkout.record(main, "i1", "certify", %{
      "status" => "failed",
      "note" => "2 tests failed\nat x"
    })

    assert_receive {:report, report}, 5_000
    refute_receive {:report, _}, 300

    assert %{
             "project" => "p1",
             "work" => "i1",
             "kind" => "issue",
             "title" => "Fix the thing",
             "steps" => [
               %{"name" => "fix", "actor" => "coder"},
               %{"name" => "certify", "actor" => "system"},
               %{"name" => "review", "actor" => "reviewer"},
               %{"name" => "promote", "actor" => "system"}
             ],
             "step" => "fix",
             "status" => "running",
             "note" => "2 tests failed"
           } = report

    assert report["commit"] == head(main)
    assert {:ok, _, _} = DateTime.from_iso8601(report["at"])
    assert "" <> _ = report["machine"]
    assert report["machine"] != ""
  end

  test "loop-reports-to-server: a landing report carries the landed commit and the evidence folder",
       %{main: main} do
    issue(main)
    stand_in()

    Checkout.record(main, "i1", "certify", %{"status" => "passed"})
    Checkout.record(main, "i1", "review", %{"status" => "pass"})
    Checkout.record(main, "i1", "promote", %{"status" => "promoted", "commit" => "abc123"})

    reports =
      for _ <- 1..3 do
        assert_receive {:report, report}, 5_000
        report
      end

    landing = Enum.find(reports, &(&1["status"] == "landed"))

    assert %{"landed" => "abc123", "step" => nil} = landing
    assert Map.has_key?(landing, "evidence")
  end

  test "loop-reports-to-server: a reconnect resends every work in flight", %{main: main} do
    work = issue(main)
    File.mkdir_p!(Workflow.Run.works_dir())
    File.write!(Path.join(Workflow.Run.works_dir(), "i1.json"), Jason.encode!(work))

    socket = Slipstream.new_socket() |> Slipstream.Socket.assign(:topic, "loop:p1")

    assert {:ok, socket} = Workflow.Server.handle_join("loop:p1", %{}, socket)
    assert_receive {:report, %{"work" => "i1", "status" => "running"}}

    # Joined again, after the line dropped.
    assert {:ok, _socket} = Workflow.Server.handle_join("loop:p1", %{}, socket)
    assert_receive {:report, %{"work" => "i1", "status" => "running"}}
    refute_receive {:report, _}, 100
  end

  test "loop-reports-to-server: start reports a journey file with no work as not started",
       %{tmp_dir: dir} do
    journey = "id: j1\nkind: journey\ntitle: Signing up\ntext: |-\n  x\nstages: []\n"
    begun = "id: j2\nkind: journey\ntext: |-\n  y\nstages: []\n"
    story = "id: s1\nkind: story\ntext: |-\n  z\ncriteria: []\n"

    repo =
      repo_with(Path.join(dir, "repo"), [
        {"stories/j1.yml", journey},
        {"stories/j2.yml", begun},
        {"stories/s1.yml", story}
      ])

    Checkout.keep(repo, "j2", %{"kind" => "journey", "id" => "j2", "root" => repo})
    Application.put_env(:workflow, :manager, %{"repo" => repo})
    socket = Slipstream.new_socket() |> Slipstream.Socket.assign(:topic, "loop:p1")

    assert {:ok, joined} = Workflow.Server.handle_join("loop:p1", %{}, socket)
    assert_receive {:report, report}
    refute_receive {:report, _}, 100

    assert %{
             "project" => "p1",
             "work" => "j1",
             "kind" => "journey",
             "title" => "Signing up",
             "status" => "not started",
             "steps" => [%{"name" => "specify", "actor" => "qa"} | _] = steps
           } = report

    assert %{"name" => "approve", "actor" => "owner"} in steps

    # Only when the loop starts, not at each rejoin.
    assert {:ok, _} = Workflow.Server.handle_join("loop:p1", %{}, joined)
    refute_receive {:report, _}, 100

    # A journey file deleted from the repository is no longer reported.
    File.rm!(Path.join(repo, "stories/j1.yml"))
    assert {:ok, _} = Workflow.Server.handle_join("loop:p1", %{}, socket)
    refute_receive {:report, _}, 100
  end

  test "loop-reports-to-server: a send with the connection down does not stop the step",
       %{main: main} do
    issue(main)

    # No line at all: the step's result is kept, nothing is sent.
    assert :ok = Checkout.record(main, "i1", "certify", %{"status" => "passed"})
    assert Checkout.snapshot(main, "i1").results[Checkout.snapshot(main, "i1").head]["certify"]

    # A line not joined: the push fails, is logged, and nothing is queued.
    socket = Slipstream.new_socket() |> Slipstream.Socket.assign(:topic, "loop:p1")

    assert {:noreply, ^socket} =
             Workflow.Server.handle_info({:report, %{"work" => "i1"}}, socket)

    # A report that cannot be made does not stop the step either.
    stand_in()
    Checkout.keep(main, "i1", %{"kind" => "no such kind", "id" => "i1", "root" => main})
    assert :ok = Checkout.record(main, "i1", "review", %{"status" => "pass"})
    refute_receive {:report, _}, 300
  end

  test "loop-reports-to-server: an agent turn alone sends nothing", %{main: main} do
    issue(main)
    stand_in()

    # What an agent's turn and its tool calls leave: its log lines, what was said
    # to it taken, the work kept. None is a recorded step result.
    Checkout.log(Checkout.log(main), "review started (reviewer)")
    Checkout.say(main, "i1", "look at the tests")
    Checkout.heard(main, "i1")
    Checkout.keep(main, "i1", %{"kind" => "issue", "id" => "i1", "root" => main})

    refute_receive {:report, _}, 300
  end
end
