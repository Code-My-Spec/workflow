defmodule Workflow.WorksAreServerRecordsTest do
  # Not async: the command a checkout runs, the agent, the manager, the server's
  # line and where works in flight are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias Workflow.Checkout

  # The contract these build to: notes/works_contract.md.

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    was =
      for key <- [:cmd, :works_dir, :agents_run, :push, :server, :manager, :manager_run],
          do: {key, Application.get_env(:workflow, key)}

    # Git is real; `just` and agent-browser are never run, and pass.
    Application.put_env(:workflow, :cmd, fn
      command, _args, _opts when command in ["just", "agent-browser"] -> {"", 0}
      command, args, opts -> System.cmd(command, args, opts)
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    # No such remote: promote merges into the main copy and pushes nothing.
    Application.put_env(:workflow, :push, %{"remote" => "nowhere", "branch" => "main"})
    Application.put_env(:workflow, :server, %{"url" => "ws://x", "project_id" => "p1"})

    Application.put_env(:workflow, :manager_run, fn _text, opts ->
      {:ok, %{text: "", messages: opts[:messages]}}
    end)

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    git(main, ~w(init -q -b main))
    git(main, ~w(config user.name t))
    git(main, ~w(config user.email t@example.com))
    commit(main, "fix.txt", "broken\n", "first")

    # The loop's own settings: how to run a work here, not what the work is.
    agent = %{"provider" => "claude-code"}

    Application.put_env(:workflow, :manager, %{
      "repo" => main,
      "agents" => %{"coder" => agent, "reviewer" => agent}
    })

    %{main: main}
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit(dir, file, content, message) do
    File.write!(Path.join(dir, file), content)
    git(dir, ["add", file])
    git(dir, ["commit", "-q", "-m", message])
  end

  defp record(fields) do
    Map.merge(
      %{
        "id" => "i1",
        "kind" => "issue",
        "workflow" => "issue",
        "subject" => %{"text" => "The widget is broken. Fix it."},
        "status" => "queued",
        "step" => nil,
        "note" => nil,
        "claimed_by" => nil
      },
      fields
    )
  end

  # The server, stubbed: it holds the records, answers hand_in, claim and
  # claimed as notes/works_contract.md says, and updates a claimed record from
  # each report. Each message it is sent is told the test.
  defp server(records) do
    test = self()
    records = Map.new(records, &{&1["id"], &1})
    pid = spawn_link(fn -> serve(test, records) end)
    Process.register(pid, Workflow.Server)
    pid
  end

  defp serve(test, records) do
    receive do
      {:"$gen_call", from, {:push, event, payload}} ->
        send(test, {:server, event, payload})
        {reply, records} = answer(event, payload, records)
        GenServer.reply(from, reply)
        serve(test, records)

      {:report, %{"work" => id} = report} ->
        send(test, {:server, "report", report})

        records =
          case records[id] do
            %{"claimed_by" => "" <> _} = record ->
              updated = %{
                record
                | "step" => report["step"],
                  "note" => report["note"],
                  "status" => report["work_status"]
              }

              send(test, {:updated, updated})
              Map.put(records, id, updated)

            _unclaimed ->
              records
          end

        serve(test, records)

      {:records, asker} ->
        send(asker, {:records, records})
        serve(test, records)
    end
  end

  defp answer("hand_in", %{"id" => id} = handed, records) do
    record = record(Map.take(handed, ["id", "kind", "workflow", "subject"]))
    {{:ok, %{"work" => record}}, Map.put(records, id, record)}
  end

  defp answer("claim", %{"work" => id}, records) do
    case records[id] do
      %{"claimed_by" => nil} = record ->
        record = %{record | "claimed_by" => "loop-p1"}
        {{:ok, %{"work" => record}}, Map.put(records, id, record)}

      _other ->
        {{:error, %{"reason" => "not yours"}}, records}
    end
  end

  defp answer("claimed", _payload, records) do
    works =
      for {_id, %{"claimed_by" => "loop-p1", "status" => status} = record} <- records,
          status not in ["done", "stopped"],
          do: record

    {{:ok, %{"works" => works}}, records}
  end

  defp answer(_event, _payload, records), do: {{:error, %{"reason" => "unknown"}}, records}

  defp records(server) do
    send(server, {:records, self()})
    assert_receive {:records, records}, 5_000
    records
  end

  defp updates(acc \\ []) do
    receive do
      {:updated, record} -> updates([record | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp stop(main) do
    capture_log(fn ->
      Workflow.Run.cancel(%{"kind" => "issue", "id" => "i1", "repo" => main})
      Workflow.Settled.idle()
    end)
  end

  test "works-are-server-records: criterion 1 - a work is a record on the server before the loop sees it, and the loop claims that record rather than creating its own",
       %{main: main} do
    test = self()
    server = server([record(%{})])

    Application.put_env(:workflow, :agents_run, fn %{name: "fix"}, work ->
      send(test, {:fix_turn, work})
      Process.sleep(:infinity)
    end)

    # The server pushes the record it made at hand-in.
    capture_log(fn ->
      Workflow.Server.handle_message("loop:p1", "work", record(%{}), Slipstream.new_socket())
      assert_receive {:fix_turn, work}, 10_000
      # It runs on what the record says it works on.
      assert work["text"] == "The widget is broken. Fix it."
    end)

    # The loop claimed the server's record, and made none of its own.
    assert_received {:server, "claim", %{"work" => "i1"}}
    refute_received {:server, "hand_in", _}

    assert %{"i1" => %{"claimed_by" => "loop-p1", "step" => "fix", "status" => "running"}} =
             records(server)

    stop(main)
  end

  test "works-are-server-records: criterion 1 - a work handed in to the loop's manager is made a record on the server first, and the loop claims it",
       %{main: main} do
    test = self()
    server = server([])

    Application.put_env(:workflow, :agents_run, fn %{name: "fix"}, work ->
      send(test, {:fix_turn, work})
      Process.sleep(:infinity)
    end)

    hand_in =
      Enum.find(
        Workflow.Manager.tools(Workflow.Manager.configured()),
        &(&1.name == "hand_in")
      )

    capture_log(fn ->
      assert {:ok, said} =
               hand_in.execute.(
                 %{"kind" => "issue", "id" => "i1", "text" => "The widget is broken. Fix it."},
                 %{}
               )

      assert said =~ "i1: on"
      assert_receive {:fix_turn, _work}, 10_000
    end)

    # Made on the server, with what it works on, then claimed: in that order.
    assert_received {:server, "hand_in", %{"id" => "i1", "kind" => "issue"} = handed}
    assert handed["subject"]["text"] == "The widget is broken. Fix it."
    refute Map.has_key?(handed["subject"], "repo")
    assert_received {:server, "claim", %{"work" => "i1"}}

    assert %{"i1" => %{"claimed_by" => "loop-p1", "step" => "fix", "status" => "running"}} =
             records(server)

    stop(main)
  end

  test "works-are-server-records: criterion 1 - a loop whose line to the server is down still runs what is handed in to it, as before",
       %{main: main} do
    test = self()

    # A line that is up but not joined: Slipstream refuses every push.
    down =
      spawn_link(fn ->
        Stream.repeatedly(fn ->
          receive do
            {:"$gen_call", from, {:push, event, _payload}} ->
              send(test, {:server, event})
              GenServer.reply(from, {:error, :not_joined})
          end
        end)
        |> Stream.run()
      end)

    Process.register(down, Workflow.Server)

    Application.put_env(:workflow, :agents_run, fn %{name: "fix"}, work ->
      send(test, {:fix_turn, work})
      Process.sleep(:infinity)
    end)

    hand_in =
      Enum.find(
        Workflow.Manager.tools(Workflow.Manager.configured()),
        &(&1.name == "hand_in")
      )

    capture_log(fn ->
      assert {:ok, said} =
               hand_in.execute.(
                 %{"kind" => "issue", "id" => "i1", "text" => "The widget is broken. Fix it."},
                 %{}
               )

      assert said =~ "i1: on"
      assert_receive {:fix_turn, work}, 10_000
      assert work["text"] == "The widget is broken. Fix it."
    end)

    assert_received {:server, "hand_in"}
    stop(main)
  end

  test "works-are-server-records: criterion 2 - each step change the loop reports updates the claimed record on the server",
       %{main: main} do
    server = server([record(%{})])

    Application.put_env(:workflow, :agents_run, fn
      %{name: "fix"}, work ->
        commit(work["root"], "fix.txt", "fixed\n", "issue i1: the fix")
        {%{}, nil}

      %{name: "review"}, _work ->
        {%{"status" => "pass"}, nil}
    end)

    capture_log(fn ->
      Workflow.Server.handle_message("loop:p1", "work", record(%{}), Slipstream.new_socket())
      Workflow.Settled.idle()
    end)

    assert Checkout.landed?(main, "issue", "i1")

    # Every step it went through was written onto the record, in order.
    steps = updates() |> Enum.map(& &1["step"]) |> Enum.dedup()
    assert ["fix", "certify", "review", "promote", "ci"] = steps

    # The record shows where the work is now: landed, waiting on its ci event.
    assert %{"i1" => %{"step" => "ci", "status" => "running"}} = records(server)

    stop(main)

    # Its last report, as it ends, is the record's last word too.
    assert %{"i1" => %{"status" => "stopped"}} = records(server)
  end

  test "works-are-server-records: criterion 3 - after a loop restart every claimed work resumes at the step its server record shows, with nothing lost",
       %{main: main} do
    test = self()

    # Before the restart: the work was claimed and its fix committed; the record
    # shows it at review. The loop's own works directory is gone.
    root = Checkout.root(main, "i1")
    git(main, ["worktree", "add", "-q", "-b", "issue/i1", root])
    commit(root, "fix.txt", "fixed\n", "issue i1: the fix")

    server =
      server([
        record(%{
          "claimed_by" => "loop-p1",
          "status" => "running",
          "step" => "review",
          "note" => "Review the fix."
        })
      ])

    refute File.exists?(Workflow.Run.works_dir())

    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:ran, step.name, work})
      Process.sleep(:infinity)
    end)

    capture_log(fn ->
      # The loop starts: what it kept on disk is nothing, so that alone resumes none.
      assert Workflow.Run.resume() == :ok
      refute_received {:ran, _step, _work}

      # Its first join asks the server for the works it has claimed.
      assert Workflow.Works.recover() == :ok
      assert_receive {:ran, "review", work}, 10_000

      # Nothing lost: it is the record's work, run on the record's subject.
      assert %{"id" => "i1", "kind" => "issue"} = work
      assert work["text"] == "The widget is broken. Fix it."
    end)

    assert_received {:server, "claimed", _}
    assert %{"i1" => %{"step" => "review", "status" => "running"}} = records(server)

    stop(main)
  end

  test "a restart recovers no more claimed works than the machine has slots; the rest wait for one",
       %{main: main} do
    test = self()
    Application.put_env(:workflow, :manager, Map.put(Workflow.Manager.configured(), "cap", 1))

    server(
      for id <- ["i1", "i2"],
          do: record(%{"id" => id, "claimed_by" => "loop-p1", "status" => "running"})
    )

    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:ran, step.name, work["id"]})
      Process.sleep(:infinity)
    end)

    capture_log(fn ->
      assert Workflow.Works.recover() == :ok
      assert_receive {:ran, _step, _first}, 10_000
      refute_receive {:ran, _step, _second}, 500
      assert_received {:server, "report", %{"work_status" => "queued"}}
    end)

    assert [waiting] = Path.wildcard(Path.join([Workflow.Run.works_dir(), "slot", "*.json"]))
    waiting_id = Path.basename(waiting, ".json")

    # A waiting work stopped leaves the slot queue and is reported stopped.
    capture_log(fn ->
      Workflow.Run.cancel(%{"kind" => "issue", "id" => waiting_id, "repo" => main})
    end)

    refute File.exists?(waiting)
    assert_received {:server, "report", %{"work" => ^waiting_id, "work_status" => "stopped"}}

    capture_log(fn ->
      for id <- ["i1", "i2"],
          do: Workflow.Run.cancel(%{"kind" => "issue", "id" => id, "repo" => main})

      Workflow.Settled.idle()
    end)
  end
end
