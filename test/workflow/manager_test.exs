defmodule Workflow.ManagerTest do
  # Not async: the manager and its run are the whole application's.
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Plug.Test, only: [conn: 3]
  import Plug.Conn, only: [put_req_header: 3]

  @moduletag :tmp_dir

  # The project's copy-setup and copy-teardown, as stand-ins that do nothing.
  defp stand_in_recipes(repo) do
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "justfile"), "copy-setup:\n\ncopy-teardown:\n")
  end

  # No telling of the manager is left from the test before, or to the next (see
  # Workflow.Tellings).
  setup do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)
  end

  @manager %{
    "agent" => %{"provider" => "claude-code"},
    "repo" => "/nowhere/repo"
  }

  # What the manager is run with is sent to the test, which says when it may answer.
  defp manager_run(text) do
    test = self()

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      # A landing tells the manager from a background task that can outlive the
      # test; waiting on a test that is gone would hold the manager for good.
      ref = Process.monitor(test)
      send(test, {:run, self(), message, opts})

      receive do
        :go ->
          Process.demonitor(ref, [:flush])
          {:ok, %{text: text, messages: []}}

        {:DOWN, ^ref, :process, _pid, _reason} ->
          {:ok, %{text: text, messages: []}}
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :manager_run) end)
  end

  defp configure(manager, dir) do
    was = for key <- [:manager, :works_dir], do: {key, Application.get_env(:workflow, key)}

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    if manager,
      do: Application.put_env(:workflow, :manager, manager),
      else: Application.delete_env(:workflow, :manager)

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)
  end

  defp post_say(say) do
    :post
    |> conn("/manager", Jason.encode!(%{say: say}))
    |> put_req_header("content-type", "application/json")
    |> Workflow.Router.call(Workflow.Router.init([]))
  end

  test "manager: criterion 1", %{tmp_dir: dir} do
    # With none configured, nothing is told and the route is not there.
    configure(nil, dir)
    manager_run("never")
    assert %{status: 404} = post_say("hello")
    refute_received {:run, _pid, _message, _opts}

    # With one configured, tell runs it with its brief and exactly its four tools.
    configure(@manager, dir)
    first = Task.async(fn -> Workflow.Manager.tell("one: saving crashes") end)
    assert_receive {:run, first_pid, message, opts}
    assert message =~ "saving crashes"
    assert is_binary(opts[:system_prompt]) and opts[:system_prompt] != ""

    assert opts[:tools] |> Enum.map(& &1.name) |> Enum.sort() == [
             "decide",
             "hand_in",
             "look",
             "record",
             "stop",
             "tell"
           ]

    # A second tell made while the first runs waits for it.
    second = Task.async(fn -> Workflow.Manager.tell("two") end)
    refute_receive {:run, _pid, "two", _opts}, 200

    send(first_pid, :go)
    assert_receive {:run, second_pid, "two", _opts}
    send(second_pid, :go)

    assert Task.await(first) == "never"
    assert Task.await(second) == "never"

    # And it answers what it said over HTTP.
    http = Task.async(fn -> post_say("hello") end)
    assert_receive {:run, http_pid, "hello", _opts}
    send(http_pid, :go)
    assert %{status: 200, resp_body: body} = Task.await(http)
    assert Jason.decode!(body) == %{"said" => "never"}
  end

  test "tell: the manager's tell keeps what is said for a running work in its repo, as POST /work/say does, and says plainly when there is no such work",
       %{tmp_dir: dir} do
    Application.put_env(:workflow, :cmd, fn
      "git", ["worktree" | _], _opts -> {"worktree /main copy\nHEAD abc\n", 0}
      "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts -> {"trunk\n", 0}
      "git", ["rev-list" | _], _opts -> {"0\n", 0}
      "git", ["rev-parse", "--path-format=absolute" | _], _opts -> {dir <> "\n", 0}
      "git", ["rev-parse" | _], _opts -> {"t0\n", 0}
      "git", _args, _opts -> {"", 0}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    repo = Path.join(dir, "repo")
    configure(%{"repo" => repo}, dir)
    root = Workflow.Checkout.root(repo, "i1")
    File.mkdir_p!(root)
    Workflow.Checkout.keep(root, "i1", %{"kind" => "issue", "id" => "i1", "text" => "Fix it."})

    tell = Enum.find(Workflow.Manager.tools(Workflow.Manager.configured()), &(&1.name == "tell"))

    assert {:ok, "i1: told."} = tell.execute.(%{"id" => "i1", "say" => "mind the migration"}, %{})
    assert Workflow.Checkout.heard(root, "i1") == ["mind the migration"]

    assert {:ok, "There is no work i9 running."} =
             tell.execute.(%{"id" => "i9", "say" => "hello"}, %{})
  end

  test "chat-interview: criterion 4 - the brief says requests arrive already interviewed, criteria are written from what is given, and it asks back only when something a test would need is missing",
       %{tmp_dir: dir} do
    configure(@manager, dir)
    manager_run("never")
    task = Task.async(fn -> Workflow.Manager.tell("one: a request") end)
    assert_receive {:run, pid, _message, opts}, 2000
    send(pid, :go)
    Task.await(task)

    brief = String.downcase(opts[:system_prompt])

    assert brief =~ "arrive already interviewed"
    assert brief =~ "write the criteria from what you are given"
    assert brief =~ "ask back, in your reply, only when something a test would need is missing"
  end

  test "story-shape: the brief says to write a request up as rules and scenarios, record anything unsettled as questions, and hand in a story with open questions only when the person says to go ahead anyway",
       %{tmp_dir: dir} do
    configure(@manager, dir)
    manager_run("never")
    task = Task.async(fn -> Workflow.Manager.tell("one: a request") end)
    assert_receive {:run, pid, _message, opts}, 2000
    send(pid, :go)
    Task.await(task)

    brief = opts[:system_prompt] |> String.downcase() |> String.replace(~r/\s+/, " ")

    assert brief =~ "write a request up as rules and scenarios"
    assert brief =~ "record anything unsettled as questions"

    assert brief =~
             "hand in a story that still has open questions only when the person says to go ahead anyway"
  end

  test "loop-failures: the brief says a failure the loop reports is the manager's to act on at once, by handing in an issue with its text, without asking; asking is only for what a person must decide",
       %{tmp_dir: dir} do
    configure(@manager, dir)
    manager_run("never")
    task = Task.async(fn -> Workflow.Manager.tell("one: a request") end)
    assert_receive {:run, pid, _message, opts}, 2000
    send(pid, :go)
    Task.await(task)

    brief = opts[:system_prompt] |> String.downcase() |> String.replace(~r/\s+/, " ")

    assert brief =~
             "a push the box refuses or fails is a failure of this app, and yours to act on at once"

    assert brief =~ "hand in an issue with the failure's text, without asking anyone"
    assert brief =~ "ask only about what a person must decide"
  end

  test "loop-bugs-are-not-app-issues: the brief says a failure of the loop is told to the person in plain words and not handed in as an issue in this app; only a failure of the app's own code or checks is",
       %{tmp_dir: dir} do
    configure(@manager, dir)
    manager_run("never")
    task = Task.async(fn -> Workflow.Manager.tell("one: a request") end)
    assert_receive {:run, pid, _message, opts}, 2000
    send(pid, :go)
    Task.await(task)

    brief = opts[:system_prompt] |> String.downcase() |> String.replace(~r/\s+/, " ")

    assert brief =~ "a failure of the loop itself"
    assert brief =~ "a record refused because the main copy has uncommitted changes"
    assert brief =~ "a step sent back three times with the same tree and note"

    assert brief =~
             "tell the person in plain words and never hand it in as an issue in this app"

    assert brief =~ "hand in an issue only for a failure of the app's own code or checks"
    refute brief =~ "a failure the loop itself reports to you"
  end

  # The loop's report to the manager, answered by the manager's stand-in turn.
  defp report_answered(answer, dir) do
    configure(@manager, dir)
    manager_run(answer)

    task =
      Task.async(fn ->
        Workflow.Messages.say(
          "manager",
          "workflow",
          "issue design-system: waiting on its owner at fix: sent to the coder a third time"
        )
      end)

    assert_receive {:run, pid, _message, _opts}, 2000
    send(pid, :go)
    Task.await(task)
  end

  test "manager-answer-reaches-the-owner: criterion 1 - the manager's answer to a message the loop sent is logged as one warning line naming the work and holding the answer",
       %{tmp_dir: dir} do
    answer = "it needs a person to fetch those dependencies"

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, ^answer} = report_answered(answer, dir)
      end)

    lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ answer))
    assert [line] = lines
    assert line =~ "[warning]"
    assert line =~ "issue design-system"
  end

  test "manager-answer-reaches-the-owner: criterion 2 - the manager's answer to a message the loop sent is kept for the owner's chat, which sees it the next time it speaks or looks",
       %{tmp_dir: dir} do
    answer = "it needs a person to fetch those dependencies"
    capture_log(fn -> report_answered(answer, dir) end)

    # The next thing the owner's chat does on POST /mcp is told a message waits.
    listed =
      :post
      |> conn("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> put_req_header("content-type", "application/json")
      |> Workflow.Router.call(Workflow.Router.init([]))

    assert %{status: 200} = listed
    assert Workflow.Messages.waiting("chat") == 1

    looked =
      :post
      |> conn(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: %{name: "inbox", arguments: %{}}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> Workflow.Router.call(Workflow.Router.init([]))

    %{"result" => %{"content" => [%{"text" => text}]}} = Jason.decode!(looked.resp_body)
    assert [%{"from" => "manager", "to" => "chat", "text" => ^answer}] = Jason.decode!(text)
  end

  test "manager-answer-reaches-the-owner: criterion 3 - the brief says the owner reads an answer to a loop report later, so it says what the manager did or exactly what a person must do",
       %{tmp_dir: dir} do
    configure(@manager, dir)
    manager_run("never")
    task = Task.async(fn -> Workflow.Manager.tell("one: a request") end)
    assert_receive {:run, pid, _message, opts}, 2000
    send(pid, :go)
    Task.await(task)

    brief = opts[:system_prompt] |> String.downcase() |> String.replace(~r/\s+/, " ")

    assert brief =~
             "nobody waits on your answer to a message from the loop: the owner reads it later, " <>
               "so say what you did or exactly what a person must do."
  end

  test "say-where-work-lands: criterion 1 - the brief says work lands in the repository's primary checkout, on whatever branch it has, even when the repo is a linked worktree of it",
       %{tmp_dir: dir} do
    configure(@manager, dir)
    manager_run("never")
    task = Task.async(fn -> Workflow.Manager.tell("one: a request") end)
    assert_receive {:run, pid, _message, opts}, 2000
    send(pid, :go)
    Task.await(task)

    brief = opts[:system_prompt] |> String.downcase() |> String.replace(~r/\s+/, " ")

    assert brief =~ "lands in the repository's primary checkout on this machine"
    assert brief =~ "on whatever branch it has checked out"
    assert brief =~ "even when the repo you were given is a linked worktree of it"
    refute brief =~ "the branch checked out in repo"
  end

  test "say-where-work-lands: criterion 2 - the manager sees the landing target (the primary checkout's folder and branch) when its repo is a linked worktree, and its brief says to name it before the first work and whenever asked",
       %{tmp_dir: dir} do
    primary = Path.join(dir, "primary")
    linked = Path.join(dir, "linked")
    File.mkdir_p!(primary)
    File.write!(Path.join(primary, "README.md"), "hello\n")

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: primary, stderr_to_stdout: true)
      String.trim(out)
    end

    for args <- [
          ~w(init -b trunk),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial),
          ["worktree", "add", "-b", "elsewhere", linked]
        ],
        do: git.(args)

    folder = git.(~w(rev-parse --show-toplevel))

    configure(Map.put(@manager, "repo", linked), dir)
    manager_run("never")
    task = Task.async(fn -> Workflow.Manager.tell("where does work land?") end)
    assert_receive {:run, pid, _message, opts}, 2000
    send(pid, :go)
    Task.await(task)

    prompt = opts[:system_prompt]
    assert prompt =~ "work lands in #{folder}, on the branch trunk."
    refute prompt =~ "elsewhere"

    brief = prompt |> String.downcase() |> String.replace(~r/\s+/, " ")

    assert brief =~
             "name that landing target (its folder and branch) to the person before the first work you hand in, and whenever you are asked where work lands"
  end

  test "story-shape: hand_in takes a story's title, workflow, story, rules with scenarios and questions, and the work started (and its stories/<id>.yml) carries them",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    stand_in_recipes(repo)

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: {_out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

    agents = %{"qa" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))

    refute "text" in hand_in.input_schema[:required]

    rules = [
      %{
        "rule" => "Only an owner may invite.",
        "scenarios" => [
          %{"happy" => "An owner invites by email and the invite is sent."},
          %{"fails" => "A member tries to invite and is told only owners can."}
        ]
      }
    ]

    shaped = %{
      "kind" => "story",
      "id" => "s1",
      "title" => "Invite a teammate",
      "workflow" => "team-setup",
      "story" => "As an account owner I want to invite a teammate.",
      "rules" => rules,
      "questions" => ["Can an owner cancel a sent invite?"]
    }

    assert {:ok, _said} = hand_in.execute.(shaped, %{})
    assert_receive {:agent, _agent, work}, 5_000
    assert Map.take(work, Map.keys(shaped)) == shaped

    yml = File.read!(Path.join([repo <> "-s1", "proj", "stories", "s1.yml"]))
    assert yml =~ "title: Invite a teammate"
    assert yml =~ "workflow: team-setup"
    assert yml =~ "- rule: Only an owner may invite."
    assert yml =~ "- fails: A member tries to invite and is told only owners can."
    assert yml =~ "- Can an owner cancel a sent invite?"
  end

  test "record-stories: criterion 1 - the record tool writes stories/<id>.yml and the workflow file in the main copy's project, commits both in one commit named for the story, and starts no work",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
      out
    end

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(args)

    agents = %{"qa" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}

    assert record = Enum.find(tools, &(&1.name == "record")), "the manager has no record tool"

    story = %{
      "id" => "s1",
      "title" => "Invite a teammate",
      "workflow" => "team-setup",
      "story" => "As an account owner I want to invite a teammate.",
      "rules" => [
        %{
          "rule" => "Only an owner may invite.",
          "scenarios" => [
            %{"happy" => "An owner invites by email and the invite is sent."},
            %{"fails" => "A member tries to invite and is told only owners can."}
          ]
        }
      ],
      "questions" => ["Can an owner cancel a sent invite?"]
    }

    commits_before = git.(~w(rev-list --count HEAD)) |> String.trim() |> String.to_integer()

    assert {:ok, _said} = record.execute.(story, %{})

    yml = File.read!(Path.join([repo, "proj", "stories", "s1.yml"]))
    assert yml =~ "title: Invite a teammate"
    assert yml =~ "workflow: team-setup"
    assert yml =~ "- rule: Only an owner may invite."
    assert yml =~ "- fails: A member tries to invite and is told only owners can."
    assert yml =~ "- Can an owner cancel a sent invite?"

    assert File.read!(Path.join([repo, "proj", "workflows", "team-setup.yml"])) =~ "- s1"

    # One new commit, named for the story, holding both files, leaving nothing behind.
    assert git.(~w(rev-list --count HEAD)) |> String.trim() |> String.to_integer() ==
             commits_before + 1

    assert git.(~w(log -1 --format=%s)) =~ "s1"
    changed = git.(~w(show --name-only --format= HEAD)) |> String.split("\n", trim: true)
    assert Enum.sort(changed) == ["proj/stories/s1.yml", "proj/workflows/team-setup.yml"]
    assert git.(~w(status --porcelain)) == ""

    # And no work was started.
    refute_receive {:agent, _pid, _work}, 500
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []
  end

  test "record-stories: criterion 2 - recording an id already recorded replaces the file with the new content in a new commit, and the workflow file still names the id once",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
      out
    end

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(args)

    configure(Map.merge(@manager, %{"repo" => repo, "project" => "proj"}), dir)

    test = self()

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :manager_run) end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    assert record = Enum.find(tools, &(&1.name == "record")), "the manager has no record tool"

    story = %{
      "id" => "s1",
      "title" => "Invite a teammate",
      "workflow" => "team-setup",
      "story" => "As an account owner I want to invite a teammate.",
      "rules" => [
        %{
          "rule" => "Only an owner may invite.",
          "scenarios" => [%{"happy" => "An owner invites by email and the invite is sent."}]
        }
      ],
      "questions" => ["Can an owner cancel a sent invite?"]
    }

    count = fn -> git.(~w(rev-list --count HEAD)) |> String.trim() |> String.to_integer() end

    assert {:ok, _said} = record.execute.(story, %{})
    after_first = count.()

    revised = %{
      story
      | "title" => "Invite a teammate by email",
        "questions" => ["Can an invite expire?"]
    }

    assert {:ok, _said} = record.execute.(revised, %{})

    assert count.() == after_first + 1

    yml = File.read!(Path.join([repo, "proj", "stories", "s1.yml"]))
    assert yml =~ "title: Invite a teammate by email"
    assert yml =~ "- Can an invite expire?"
    refute yml =~ "Can an owner cancel a sent invite?"

    workflow = File.read!(Path.join([repo, "proj", "workflows", "team-setup.yml"]))
    assert length(Regex.scan(~r/^  - s1$/m, workflow)) == 1
    assert git.(~w(status --porcelain)) == ""
  end

  test "record-stories: criterion 3 - recording when the main copy has uncommitted changes to that story's file is refused with a message naming the file, and nothing is committed",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join([repo, "proj", "stories"]))
    File.write!(Path.join([repo, "proj", "stories", "s1.yml"]), "title: Kept\n")

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
      out
    end

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(args)

    configure(Map.merge(@manager, %{"repo" => repo, "project" => "proj"}), dir)

    test = self()

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :manager_run) end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    assert record = Enum.find(tools, &(&1.name == "record")), "the manager has no record tool"

    # The person's own edit, not yet committed.
    edited = "title: Edited by hand\n"
    File.write!(Path.join([repo, "proj", "stories", "s1.yml"]), edited)

    head = git.(~w(rev-parse HEAD))

    story = %{
      "id" => "s1",
      "title" => "Invite a teammate",
      "workflow" => "team-setup",
      "story" => "As an account owner I want to invite a teammate.",
      "rules" => [
        %{
          "rule" => "Only an owner may invite.",
          "scenarios" => [%{"happy" => "An owner invites by email and the invite is sent."}]
        }
      ],
      "questions" => []
    }

    assert {:ok, refused} = record.execute.(story, %{})
    assert refused =~ "proj/stories/s1.yml"
    assert refused =~ ~r/refused/i

    # Nothing committed, nothing written over, no workflow file made.
    assert git.(~w(rev-parse HEAD)) == head
    assert File.read!(Path.join([repo, "proj", "stories", "s1.yml"])) == edited
    refute File.exists?(Path.join([repo, "proj", "workflows", "team-setup.yml"]))
  end

  # A main copy with the manager's record tool, for the record-survives tests.
  defp record_tool(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
      out
    end

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(args)

    configure(Map.merge(@manager, %{"repo" => repo, "project" => "proj"}), dir)

    test = self()

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :manager_run) end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    assert record = Enum.find(tools, &(&1.name == "record")), "the manager has no record tool"

    story = %{
      "id" => "s1",
      "title" => "Invite a teammate",
      "workflow" => "team-setup",
      "story" => "As an account owner I want to invite a teammate.",
      "rules" => [
        %{
          "rule" => "Only an owner may invite.",
          "scenarios" => [%{"happy" => "An owner invites by email and the invite is sent."}]
        }
      ],
      "questions" => []
    }

    {repo, git, record, story}
  end

  test "record-survives: criterion 1 - recording commits only the files it wrote, whatever else is uncommitted in the main copy",
       %{tmp_dir: dir} do
    {repo, git, record, story} = record_tool(dir)

    # A person's unrelated work: one file edited, one staged.
    File.write!(Path.join([repo, "proj", "README.md"]), "edited\n")
    File.write!(Path.join([repo, "proj", "notes.md"]), "notes\n")
    git.(["add", "proj/notes.md"])

    assert {:ok, said} = record.execute.(story, %{})
    assert said =~ "recorded in"

    changed = git.(~w(show --name-only --format= HEAD)) |> String.split("\n", trim: true)
    assert Enum.sort(changed) == ["proj/stories/s1.yml", "proj/workflows/team-setup.yml"]

    # The person's work is left as it was.
    assert git.(~w(status --porcelain)) |> String.split("\n", trim: true) |> Enum.sort() ==
             [" M proj/README.md", "A  proj/notes.md"]
  end

  test "record-survives: criterion 2 - a retry over a file left behind by an earlier failed record succeeds",
       %{tmp_dir: dir} do
    {repo, git, record, story} = record_tool(dir)

    # The first record's commit fails, leaving its files written and uncommitted.
    hook = Path.join([repo, ".git", "hooks", "pre-commit"])
    File.mkdir_p!(Path.dirname(hook))
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)

    assert {:ok, failed} = record.execute.(story, %{})
    assert failed =~ "not recorded"
    assert git.(["status", "--porcelain", "--", "proj/stories/s1.yml"]) != ""

    File.rm!(hook)
    head = git.(~w(rev-parse HEAD))

    assert {:ok, said} = record.execute.(story, %{})
    assert said =~ "recorded in"
    refute git.(~w(rev-parse HEAD)) == head

    changed = git.(~w(show --name-only --format= HEAD)) |> String.split("\n", trim: true)
    assert Enum.sort(changed) == ["proj/stories/s1.yml", "proj/workflows/team-setup.yml"]
    assert git.(~w(status --porcelain)) == ""
  end

  test "record-stories: criterion 4 - hand_in with a kind of story and only the id of a recorded story starts the work with the text and scenarios read from stories/<id>.yml, and the work makes no second story commit when the file is unchanged",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn cd, args ->
      {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      out
    end

    stand_in_recipes(repo)

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(repo, args)

    agents = %{"qa" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    record = Enum.find(tools, &(&1.name == "record"))
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))

    rules = [
      %{
        "rule" => "Only an owner may invite.",
        "scenarios" => [
          %{"happy" => "An owner invites by email and the invite is sent."},
          %{"fails" => "A member tries to invite and is told only owners can."}
        ]
      }
    ]

    story = %{
      "id" => "s1",
      "title" => "Invite a teammate",
      "workflow" => "team-setup",
      "story" => "As an account owner I want to invite a teammate.",
      "rules" => rules,
      "questions" => []
    }

    assert record, "the manager has no record tool"
    assert {:ok, _said} = record.execute.(story, %{})

    # Handed in by its id alone.
    assert {:ok, _said} = hand_in.execute.(%{"kind" => "story", "id" => "s1"}, %{})
    assert_receive {:agent, _agent, work}, 5_000

    assert work["title"] == "Invite a teammate"
    assert work["rules"] == rules
    assert work["criteria"] |> List.wrap() |> length() == 2

    # The work's checkout holds the one story commit, the recording's.
    story_commits =
      git.(repo <> "-s1", ~w(log --format=%s))
      |> String.split("\n", trim: true)
      |> Enum.filter(&(&1 =~ "story s1:"))

    assert length(story_commits) == 1
  end

  test "record-stories: criterion 5 - hand_in with only an id that has no recorded file is refused with a message that says so",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: {_out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

    agents = %{"qa" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))

    assert {:ok, refused} = hand_in.execute.(%{"kind" => "story", "id" => "nope"}, %{})
    assert refused =~ "nope"
    assert refused =~ ~r/refused/i
    assert refused =~ ~r/no .*recorded|not recorded/i

    # And nothing was started.
    refute_receive {:agent, _pid, _work}, 300
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []
    refute File.exists?(repo <> "-nope")
  end

  test "record-stories: criterion 6 - hand_in with the full fields writes the story file in the work's first commit, as today",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn cd, args ->
      {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      out
    end

    stand_in_recipes(repo)

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(repo, args)

    agents = %{"qa" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))

    full = %{
      "kind" => "story",
      "id" => "s1",
      "title" => "Invite a teammate",
      "workflow" => "team-setup",
      "story" => "As an account owner I want to invite a teammate.",
      "rules" => [
        %{
          "rule" => "Only an owner may invite.",
          "scenarios" => [%{"happy" => "An owner invites by email and the invite is sent."}]
        }
      ],
      "questions" => []
    }

    assert {:ok, _said} = hand_in.execute.(full, %{})
    assert_receive {:agent, _agent, work}, 5_000
    assert work["title"] == "Invite a teammate"

    # The work's first commit, on top of the main copy's, holds the story file and its workflow entry.
    checkout = repo <> "-s1"
    base = git.(repo, ~w(rev-parse HEAD)) |> String.trim()

    commits =
      git.(checkout, ["rev-list", "--reverse", "#{base}..HEAD"])
      |> String.split("\n", trim: true)

    assert [first | _] = commits
    assert git.(checkout, ["log", "-1", "--format=%s", first]) =~ "story s1:"

    changed =
      git.(checkout, ["show", "--name-only", "--format=", first])
      |> String.split("\n", trim: true)
      |> Enum.sort()

    assert changed == ["proj/stories/s1.yml", "proj/workflows/team-setup.yml"]

    yml = git.(checkout, ["show", "#{first}:proj/stories/s1.yml"])
    assert yml =~ "title: Invite a teammate"
    assert yml =~ "- rule: Only an owner may invite."
  end

  test "issues-leave-a-file: an issue handed in is written to issues/<id>.yml in the main copy, with its title, text and criteria, and committed as a story is",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn cd, args ->
      {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      out
    end

    stand_in_recipes(repo)

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(repo, args)

    agents = %{"coder" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))

    issue = %{
      "kind" => "issue",
      "id" => "i1",
      "title" => "Saving crashes",
      "text" => "Saving a draft crashes the page.\nIt worked last week.\n",
      "criteria" => ["saving a draft keeps it", "no crash is logged"]
    }

    assert {:ok, _said} = hand_in.execute.(issue, %{})
    assert_receive {:agent, _agent, _work}, 5_000

    # The main copy's last commit holds the issue's file, and only it.
    assert git.(repo, ["log", "-1", "--format=%s"]) =~ "issue i1:"

    assert git.(repo, ["show", "--name-only", "--format=", "HEAD"])
           |> String.split("\n", trim: true) == ["proj/issues/i1.yml"]

    refute Workflow.Checkout.changed?(repo, "proj/issues/i1.yml")

    yml = git.(repo, ["show", "HEAD:proj/issues/i1.yml"])
    assert yml =~ "title: Saving crashes\n"
    assert yml =~ "text: |\n  Saving a draft crashes the page.\n  It worked last week.\n"
    assert yml =~ "criteria:\n  - \"saving a draft keeps it\"\n  - \"no crash is logged\"\n"
  end

  test "system-steps-outlive-their-caller: hand_in answers the path of the work's log at the tree it was handed in at, and look the path at the tree it is at now",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn cd, args ->
      {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      String.trim(out)
    end

    stand_in_recipes(repo)

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(repo, args)

    agents = %{"coder" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    tool = &Enum.find(tools, fn tool -> tool.name == &1 end)

    issue = %{"kind" => "issue", "id" => "i1", "text" => "Saving crashes."}
    assert {:ok, said} = tool.("hand_in").execute.(issue, %{})
    assert_receive {:agent, _agent, _work}, 5_000

    checkout = Workflow.Checkout.root(repo, "i1")
    common = git.(checkout, ~w(rev-parse --path-format=absolute --git-common-dir))
    tree = git.(checkout, ~w(rev-parse HEAD^{tree}))
    log = Path.join([common, "workflow", "analysis", tree, "log"])

    assert said =~ "Its log: #{log}"
    assert File.read!(log) =~ "fix started (coder)"

    assert {:ok, seen} = tool.("look").execute.(%{"id" => "i1", "kind" => "issue"}, %{})
    assert %{"log" => ^log, "working" => true} = Jason.decode!(seen)
  end

  test "hand-in-outlives-copy-setup: a hand-in whose copy-setup outlasts the tool timeout answers at once, is in flight, and the work goes on to its next step",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")
    # A copy-setup that outlasts the tool's timeout, shortened here to one second.
    File.write!(
      Path.join([repo, "proj", "justfile"]),
      "copy-setup:\n\tsleep 3\n\ncopy-teardown:\n"
    )

    git = fn cd, args ->
      {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      String.trim(out)
    end

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(repo, args)

    agents = %{"coder" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:agent, step.name, work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))
    issue = %{"kind" => "issue", "id" => "i1", "text" => "Saving crashes."}

    # The tool call, killed as Alloy kills one that overruns its timeout.
    call = Task.async(fn -> hand_in.execute.(issue, %{}) end)
    answered = Task.yield(call, 1_000) || Task.shutdown(call, :brutal_kill)

    assert {:ok, {:ok, said}} = answered
    assert said =~ "i1: on copy-setup (system), started."
    assert File.exists?(Path.join(Workflow.Run.works_dir(), "i1.json"))

    # Its copy-setup completes, and the work goes on to its next step.
    assert_receive {:agent, "fix", %{"root" => root}}, 15_000
    assert root == Workflow.Checkout.root(repo, "i1")
    assert File.exists?(Path.join(Workflow.Run.works_dir(), "i1.json"))
  end

  test "provisioning-is-a-work: criterion 1 - a provision handed in with hand_in is kept as provisions/<id>.yml in the main copy and the work starts",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn cd, args ->
      {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      out
    end

    stand_in_recipes(repo)

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(repo, args)

    agents = %{"coder" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    # Its steps, and a stand-in `just provision` that fails, so the work goes to the coder.
    File.mkdir_p!(Path.join([repo, "proj", "provision"]))
    File.write!(Path.join([repo, "proj", "provision", "staging.steps"]), "start-server\n")
    git.(repo, ~w(add -A))
    git.(repo, ~w(commit -m steps))

    Application.put_env(:workflow, :cmd, fn
      "just", ["copy-" <> _] = args, opts -> System.cmd("just", args, opts)
      "just", _args, _opts -> {"no server", 1}
      command, args, opts -> System.cmd(command, args, opts)
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))

    assert "provision" in hand_in.input_schema[:properties][:kind][:enum]

    provision = %{
      "kind" => "provision",
      "id" => "p1",
      "title" => "A place to run",
      "text" => "Stand up the server.\n",
      "criteria" => ["the server answers"],
      "target" => "staging"
    }

    assert {:ok, said} = hand_in.execute.(provision, %{})
    refute said =~ "Refused"
    assert_receive {:agent, _agent, %{"kind" => "provision", "id" => "p1"}}, 5_000

    assert git.(repo, ["show", "--name-only", "--format=", "HEAD"])
           |> String.split("\n", trim: true) == ["proj/provisions/p1.yml"]

    yml = git.(repo, ["show", "HEAD:proj/provisions/p1.yml"])
    assert yml =~ "kind: \"provision\"\n"
    assert yml =~ "title: A place to run\n"
    # provision-has-targets: hand_in takes the target, and the file records it.
    assert yml =~ ~r/target: "?staging"?\n/
  end

  test "provision-has-targets: criterion 4", %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join([repo, "proj", "provision"]))
    File.write!(Path.join([repo, "proj", "provision", "staging.steps"]), "start-server\n")

    git = fn cd, args ->
      {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      out
    end

    stand_in_recipes(repo)

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(repo, args)

    agents = %{"coder" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    # A stand-in `just provision` that fails, so nothing real is reached.
    Application.put_env(:workflow, :cmd, fn
      "just", ["copy-" <> _] = args, opts -> System.cmd("just", args, opts)
      "just", _args, _opts -> {"no server", 1}
      command, args, opts -> System.cmd(command, args, opts)
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
      Application.delete_env(:workflow, :cmd)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))

    provision = %{
      "kind" => "provision",
      "id" => "p4",
      "title" => "A place to run",
      "text" => "Stand up the server.\n",
      "criteria" => ["the server answers"],
      "target" => "staging"
    }

    assert {:ok, said} = hand_in.execute.(provision, %{})
    refute said =~ "Refused"

    # Its failed provision step, run after hand_in answers, hands it to the coder.
    assert_receive {:agent, _pid, %{"id" => "p4"}}, 5_000

    assert git.(repo, ["show", "HEAD:proj/provisions/p4.yml"]) =~ ~r/target: "?staging"?\n/
  end

  test "stop-a-work: the manager's stop tool stops a running work for good: no agent runs on it again, its checkout and branch are removed, its issue file is removed from the main copy in a commit, and it never promotes",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn cd, args ->
      {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      out
    end

    stand_in_recipes(repo)

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(repo, args)

    agents = %{"coder" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    # The agent commits a change in the checkout when it is let go, as a coder would.
    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})

      receive do
        :go ->
          if File.dir?(work["root"]) do
            File.write!(Path.join([work["root"], "proj", "fix.txt"]), "fixed\n")
            System.cmd("git", ~w(add -A), cd: work["root"])
            System.cmd("git", ~w(commit -m fix), cd: work["root"])
          end

          {%{}, nil}
      end
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    tool = fn name -> Enum.find(tools, &(&1.name == name)) end

    issue = %{"kind" => "issue", "id" => "i1", "title" => "Wrong", "text" => "Not wanted.\n"}
    assert {:ok, _said} = tool.("hand_in").execute.(issue, %{})
    assert_receive {:agent, agent, _work}, 5_000

    root = Workflow.Checkout.root(repo, "i1")
    assert File.dir?(root)
    assert git.(repo, ~w(branch --list issue/i1)) =~ "issue/i1"
    assert File.exists?(Path.join([repo, "proj", "issues", "i1.yml"]))

    assert {:ok, said} = tool.("stop").execute.(%{"id" => "i1", "kind" => "issue"}, %{})
    assert said =~ "i1: stopped"

    # Its checkout and branch are gone, and it is no longer in flight.
    refute File.exists?(root)
    assert git.(repo, ~w(branch --list issue/i1)) == ""
    assert Path.wildcard(Path.join([dir, "works", "*.json"])) == []

    # Its issue file is removed from the main copy, in a commit of that removal alone.
    refute File.exists?(Path.join([repo, "proj", "issues", "i1.yml"]))
    refute Workflow.Checkout.changed?(repo, "proj/issues/i1.yml")
    assert git.(repo, ["log", "-1", "--format=%s"]) =~ "issue i1: stopped"

    assert git.(repo, ["show", "--name-status", "--format=", "HEAD"])
           |> String.split("\n", trim: true) == ["D\tproj/issues/i1.yml"]

    head = git.(repo, ~w(rev-parse HEAD))

    # The turn running when it was stopped ends: no agent runs on it again, no
    # checkout is cut again, and nothing lands in the main copy.
    ref = Process.monitor(agent)
    send(agent, :go)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
    refute_receive {:agent, _agent, _work}, 500
    refute File.exists?(root)
    assert git.(repo, ~w(rev-parse HEAD)) == head

    # Neither handing it in again nor resuming runs it, or promotes it.
    assert {:ok, again} = tool.("hand_in").execute.(Map.delete(issue, "title"), %{})
    assert again =~ "stopped for good"
    refute File.exists?(Path.join([repo, "proj", "issues", "i1.yml"]))
    assert git.(repo, ~w(rev-parse HEAD)) == head

    assert Workflow.Run.start(%{"kind" => "issue", "id" => "i1", "repo" => repo}) ==
             {:cancelled, nil}

    assert Workflow.Run.step(%{"kind" => "issue", "id" => "i1", "repo" => repo}) == :cancelled
    refute_receive {:agent, _agent, _work}, 500
    refute File.exists?(root)
    refute git.(repo, ["log", "--format=%s"]) =~ "Merge"
  end

  test "manager: criterion 2", %{tmp_dir: dir} do
    configure(@manager, dir)
    test = self()

    # Each run is sent the conversation it was given, and adds the message it was told.
    Application.put_env(:workflow, :manager_run, fn message, opts ->
      send(test, {:ran, message, opts[:messages]})
      kept = opts[:messages] ++ [%{role: :user, content: message}]
      {:ok, %{text: "ok", messages: kept}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :manager_run) end)

    assert Workflow.Manager.tell("one") == "ok"
    assert_received {:ran, "one", []}

    # One file beside the works directory holds it, so it outlives the process.
    assert [_one_file] = Path.wildcard(Path.join(dir, "manager.*"))

    assert Workflow.Manager.tell("two") == "ok"
    assert_received {:ran, "two", [%{role: :user, content: "one"}]}
  end

  test "manager: criterion 3", %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    agents = %{"coder" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{
        "repo" => repo,
        "project" => "workflow",
        "agents" => agents,
        "cap" => 1
      }),
      dir
    )

    test = self()

    # A checkout at tree t1 with one commit for the journey `j1`, t0 with none otherwise.
    Application.put_env(:workflow, :cmd, fn command, args, opts ->
      send(test, {command, args})
      n = if String.ends_with?(opts[:cd] || "", "-j1"), do: 1, else: 0

      case {command, args} do
        {"git", ["worktree", "add" | add_args]} ->
          File.mkdir_p!(List.last(add_args))
          {"", 0}

        {"git", ["rev-parse", "HEAD^{tree}"]} ->
          {"t#{n}\n", 0}

        {"git", ["worktree" | _]} ->
          {"worktree /main copy\nHEAD abc\n", 0}

        {"git", ["rev-parse", "--abbrev-ref", "HEAD"]} ->
          {"trunk\n", 0}

        {"git", ["rev-list" | _]} ->
          {"#{n}\n", 0}

        {"git", ["status" | _]} ->
          {"", 0}

        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} ->
          {dir <> "\n", 0}

        {"git", ["rev-parse", "HEAD"]} ->
          {"c#{n}\n", 0}

        {"git", ["branch" | _]} ->
          {"", 0}

        {"git", ["merge" | _]} ->
          {"", 0}

        {"git", ["remote" | _]} ->
          {"", 0}

        {"git", ["push" | _]} ->
          {"", 0}

        {"mix", _args} ->
          {"", 0}

        {"just", _args} ->
          {"1 test", 0}
      end
    end)

    # An agent that is handed a work says so, and stays at it.
    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :cmd)
      Application.delete_env(:workflow, :agents_run)
    end)

    # A journey `j1` waiting on its owner's demo: reviewed, its stage named and tested.
    root = repo <> "-j1"
    File.mkdir_p!(Path.join([root, "workflow", "test"]))

    File.write!(
      Path.join([root, "workflow", "test", "journey_test.exs"]),
      "test \"j1: stage 1\" do\nend\n"
    )

    kept = %{
      "kind" => "journey",
      "id" => "j1",
      "text" => "sign up",
      "stages" => ["the user signs up"]
    }

    File.mkdir_p!(Path.join(dir, "workflow"))

    File.write!(
      Path.join([dir, "workflow", "j1.json"]),
      Jason.encode!(%{"work" => kept, "t1" => %{"review" => %{"status" => "pass"}}})
    )

    # The manager's tools, as the run is given them.
    Application.put_env(:workflow, :manager_run, fn message, opts ->
      send(test, {:tools, opts[:tools]})
      send(test, {:told, message})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :manager_run) end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}

    use_tool = fn name, input ->
      tool = Enum.find(tools, &(&1.name == name))
      tool.execute.(input, %{})
    end

    # look answers what GET /works/:id answers.
    asked = %{"kind" => "journey", "id" => "j1", "root" => root}
    assert {:ok, seen} = use_tool.("look", %{"id" => "j1", "kind" => "journey"})

    assert Jason.decode!(seen) ==
             asked |> Workflow.Run.look() |> Jason.encode!() |> Jason.decode!()

    # hand_in starts a work with the configured repo, project and agents added.
    input = %{"kind" => "issue", "id" => "i1", "text" => "saving crashes"}
    assert {:ok, _said} = use_tool.("hand_in", input)
    # Its copy is made, and its agent started, after hand_in answers.
    assert_receive {:agent, agent, work}, 2_000
    assert %{"repo" => ^repo, "project" => "workflow", "agents" => ^agents} = work
    assert %{"kind" => "issue", "id" => "i1", "text" => "saving crashes"} = work

    # With one work in flight and a cap of one, it refuses in words, and starts nothing.
    assert {:ok, refused} = use_tool.("hand_in", %{input | "id" => "i2"})
    assert refused =~ ~r/cap|in flight/i
    refute_receive {:agent, _pid, %{"id" => "i2"}}, 200

    # decide hands the waiting work in again with the owner's decision.
    assert {:ok, _said} =
             use_tool.("decide", %{"id" => "j1", "kind" => "journey", "demo" => "approve"})

    # Its promote is the system's, run after decide answers.
    assert_receive {"git", ["merge", "--no-ff", "--no-edit", "c1"]}, 2_000

    # Its landing tells the manager in the background: waited for too, or the
    # telling outlives this test and runs the next test's (or a real) manager.
    assert_receive {:told, "journey j1: " <> _}, 5_000

    # The killed agent's work is stopped and the manager told so: waited for here,
    # so the telling never lands in the next test's manager.
    capture_log(fn ->
      Process.exit(agent, :kill)
      assert_receive {:told, "issue i1: stopped" <> _}, 5_000
    end)
  end

  test "prod-waits-for-the-owner: criterion 4 - neither the manager's decide nor a say from the chat starts a waiting prod provision's steps",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    configure(Map.put(@manager, "repo", repo), dir)
    test = self()

    Application.put_env(:workflow, :cmd, fn command, args, _opts ->
      send(test, {command, args})

      case {command, args} do
        {"git", ["worktree", "add" | add_args]} ->
          File.mkdir_p!(List.last(add_args))
          {"", 0}

        {"git", ["rev-parse", "HEAD^{tree}"]} ->
          {"t0\n", 0}

        {"git", ["worktree" | _]} ->
          {"worktree /main copy\nHEAD abc\n", 0}

        {"git", ["rev-parse", "--abbrev-ref", "HEAD"]} ->
          {"trunk\n", 0}

        {"git", ["rev-list" | _]} ->
          {"0\n", 0}

        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} ->
          {dir <> "\n", 0}

        {"git", ["rev-parse", "HEAD"]} ->
          {"c0\n", 0}

        {"git", _args} ->
          {"", 0}

        {"just", _args} ->
          {"", 0}
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    root = repo <> "-p1"
    File.mkdir_p!(Path.join([root, "workflow", "provision"]))
    File.write!(Path.join([root, "workflow", "provision", "prod.steps"]), "a\n")

    work = %{
      "kind" => "provision",
      "id" => "p1",
      "repo" => repo,
      "project" => "workflow",
      "target" => "prod"
    }

    # Set before the work starts: its wait tells the manager, which must not be the real one.
    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :manager_run) end)

    capture_log(fn -> Workflow.Run.start(work) end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    decide = Enum.find(tools, &(&1.name == "decide"))

    capture_log(fn ->
      decide.execute.(%{"id" => "p1", "kind" => "provision", "demo" => "approve"}, %{})
    end)

    say =
      conn(:post, "/work/say", Jason.encode!(%{id: "p1", repo: repo, say: "go ahead, ship it"}))
      |> put_req_header("content-type", "application/json")
      |> Workflow.Router.call(Workflow.Router.init([]))

    assert say.status == 200
    refute_receive {"just", ["provision" | _]}, 300
  end

  test "manager-criterion-4-flaky: a work a test leaves going is ended by quiet, its telling of the manager with it, so none reaches a later test",
       %{tmp_dir: dir} do
    test = self()
    configure(@manager, dir)

    Application.put_env(:workflow, :cmd, fn command, args, _opts ->
      case {command, args} do
        {"git", ["rev-parse", "HEAD^{tree}"]} -> {"t0\n", 0}
        {"git", ["worktree" | _]} -> {"worktree /main copy\nHEAD abc\n", 0}
        {"git", ["rev-parse", "--abbrev-ref", "HEAD"]} -> {"trunk\n", 0}
        {"git", ["rev-list" | _]} -> {"0\n", 0}
        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} -> {dir <> "\n", 0}
        _other -> {"", 0}
      end
    end)

    # An agent held for good, as many tests here leave theirs.
    Application.put_env(:workflow, :agents_run, fn _step, _work ->
      send(test, {:agent, self()})
      receive do: (:never -> {%{}, nil})
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :cmd)
      Application.delete_env(:workflow, :agents_run)
    end)

    work = %{
      "kind" => "issue",
      "id" => "q1",
      "root" => dir,
      "agent" => %{"provider" => "claude-code"}
    }

    assert {_step, "started"} = Workflow.Run.start(work)
    assert_receive {:agent, agent}, 5_000
    capture_log(&Workflow.Tellings.quiet/0)

    # Nothing of the work is left to tell the manager after the test.
    refute Process.alive?(agent)

    assert [] =
             for(
               pid <- Process.list(),
               {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
               match?({Workflow.Run, _name, 0}, dictionary[:"$initial_call"]),
               do: pid
             )
  end

  test "manager: criterion 4", %{tmp_dir: dir} do
    # The stand-in first: never a manager configured with none, which runs the real one.
    manager_run("noted")
    configure(@manager, dir)

    Application.put_env(:workflow, :cmd, fn command, args, _opts ->
      case {command, args} do
        {"git", ["rev-parse", "HEAD^{tree}"]} -> {"t0\n", 0}
        {"git", ["worktree" | _]} -> {"worktree /main copy\nHEAD abc\n", 0}
        {"git", ["rev-parse", "--abbrev-ref", "HEAD"]} -> {"trunk\n", 0}
        {"git", ["rev-list" | _]} -> {"0\n", 0}
        {"git", ["status" | _]} -> {"", 0}
        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} -> {dir <> "\n", 0}
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    # An agent that cannot run leaves the work stopped, with a reason.
    work = %{
      "kind" => "issue",
      "id" => "m4",
      "root" => dir,
      "agent" => %{"provider" => "not-a-real-provider"}
    }

    capture_log(fn ->
      # The manager is held on its answer, yet the loop gets on: it never waits on it.
      assert {_step, note} = Workflow.Run.start(work)
      assert note =~ "not started"
    end)

    assert_receive {:run, pid, "issue m4: " <> _ = message, _opts}
    assert message =~ "m4"
    assert message =~ "stopped"
    assert message =~ "not started"
    refute message =~ "\n"
    send(pid, :go)

    # And a person or program can say something to it, and has its answer.
    http = Task.async(fn -> post_say("hello") end)
    assert_receive {:run, http_pid, "hello", _opts}
    send(http_pid, :go)
    assert %{status: 200, resp_body: body} = Task.await(http)
    assert Jason.decode!(body) == %{"said" => "noted"}
  end

  test "record-personas: criterion 1 - the record tool given personas writes personas.yml in the main copy's project as a list in field order and commits it, starting no work",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
      out
    end

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(args)

    agents = %{"qa" => %{"provider" => "claude-code"}}

    configure(
      Map.merge(@manager, %{"repo" => repo, "project" => "proj", "agents" => agents}),
      dir
    )

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, self(), work})
      receive do: (:never -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}

    assert record = Enum.find(tools, &(&1.name == "record")), "the manager has no record tool"

    personas = [
      %{
        "name" => "Ana",
        "guess" => "Probably a founder",
        "pays" => "Monthly plan",
        "refuses" => "Long forms",
        "uses" => "Phone",
        "today" => "Keeps notes in a spreadsheet",
        "wants" => "To see her people in one place",
        "main" => "The owner of the shop"
      },
      %{"name" => "Bo", "wants" => "Fewer emails"}
    ]

    commits_before = git.(~w(rev-list --count HEAD)) |> String.trim() |> String.to_integer()

    assert {:ok, _said} = record.execute.(%{"personas" => personas}, %{})

    yml = File.read!(Path.join([repo, "proj", "personas.yml"]))

    positions =
      for key <- ~w(name main wants today uses refuses pays guess) do
        assert {pos, _len} = :binary.match(yml, "#{key}:"), "personas.yml has no #{key}:"
        pos
      end

    assert positions == Enum.sort(positions)
    assert yml =~ "Ana"
    assert yml =~ "Probably a founder"

    {ana, _} = :binary.match(yml, "Ana")
    {bo, _} = :binary.match(yml, "Bo")
    assert ana < bo
    assert yml =~ "Fewer emails"

    assert git.(~w(rev-list --count HEAD)) |> String.trim() |> String.to_integer() ==
             commits_before + 1

    changed = git.(~w(show --name-only --format= HEAD)) |> String.split("\n", trim: true)
    assert changed == ["proj/personas.yml"]
    assert git.(~w(status --porcelain)) == ""

    refute_receive {:agent, _pid, _work}, 500
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []
  end

  # A main copy with a project, the manager on it, and its record tool.
  defp personas_record(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
      out
    end

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(args)

    configure(Map.merge(@manager, %{"repo" => repo, "project" => "proj"}), dir)
    test = self()

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :manager_run) end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    record = Enum.find(tools, &(&1.name == "record"))
    count = fn -> git.(~w(rev-list --count HEAD)) |> String.trim() |> String.to_integer() end
    {repo, git, record, count}
  end

  test "record-personas: criterion 2 - recording personas again replaces personas.yml in a new commit",
       %{tmp_dir: dir} do
    {repo, _git, record, count} = personas_record(dir)

    assert {:ok, _} = record.execute.(%{"personas" => [%{"name" => "Ana"}]}, %{})
    before = count.()

    assert {:ok, _} =
             record.execute.(%{"personas" => [%{"name" => "Cy", "wants" => "Speed"}]}, %{})

    assert count.() == before + 1
    yml = File.read!(Path.join([repo, "proj", "personas.yml"]))
    assert yml =~ "Cy"
    refute yml =~ "Ana"
  end

  test "record-personas: criterion 3 - a persona with no name is refused with a message saying so, nothing committed",
       %{tmp_dir: dir} do
    {repo, git, record, count} = personas_record(dir)
    before = count.()

    assert {:ok, said} =
             record.execute.(
               %{"personas" => [%{"name" => "Ana"}, %{"wants" => "Speed"}]},
               %{}
             )

    assert said =~ "name"
    assert count.() == before
    refute File.exists?(Path.join([repo, "proj", "personas.yml"]))
    assert git.(~w(status --porcelain)) == ""
  end

  test "record-personas: criterion 4 - research text gets personas/<name>.md in the same commit; none, no file",
       %{tmp_dir: dir} do
    {repo, git, record, count} = personas_record(dir)
    before = count.()

    personas = [
      %{"name" => "Ana", "research" => "Interviewed twice.\n"},
      %{"name" => "Bo"}
    ]

    assert {:ok, _} = record.execute.(%{"personas" => personas}, %{})
    assert count.() == before + 1

    assert File.read!(Path.join([repo, "proj", "personas", "Ana.md"])) ==
             "Interviewed twice.\n"

    refute File.exists?(Path.join([repo, "proj", "personas", "Bo.md"]))

    changed = git.(~w(show --name-only --format= HEAD)) |> String.split("\n", trim: true)
    assert Enum.sort(changed) == ["proj/personas.yml", "proj/personas/Ana.md"]
  end

  test "record-personas: criterion 5 - a persona recorded without research text gets no personas/<name>.md file" do
    dir =
      System.tmp_dir!() |> Path.join("record-personas-c5-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {repo, git, record, count} = personas_record(dir)
    before = count.()

    personas = [%{"name" => "Bo", "wants" => "Fewer emails"}, %{"name" => "Cy", "research" => ""}]

    assert {:ok, _} = record.execute.(%{"personas" => personas}, %{})
    assert count.() == before + 1

    refute File.exists?(Path.join([repo, "proj", "personas", "Bo.md"]))
    refute File.exists?(Path.join([repo, "proj", "personas", "Cy.md"]))

    changed = git.(~w(show --name-only --format= HEAD)) |> String.split("\n", trim: true)
    assert changed == ["proj/personas.yml"]
  end

  # A main copy on `main`, and the manager's look tool for works cut from it.
  defp landed_repo(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README.md"), "hello\n")

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
      out
    end

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git.(args)

    look = Enum.find(Workflow.Manager.tools(%{"repo" => repo}), &(&1.name == "look"))
    {repo, git, fn id, kind -> look.execute.(%{"id" => id, "kind" => kind}, %{}) end}
  end

  # A work's branch with a commit of its own, as a story's file is committed.
  defp work_branch(repo, git, kind, id, subject) do
    git.(["checkout", "-q", "-b", "#{kind}/#{id}"])
    File.write!(Path.join(repo, "#{id}.txt"), "#{id}\n")
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", subject])
    git.(~w(checkout -q main))
  end

  test "manager-knows-what-landed: criterion 1 - look at a work with no checkout whose branch is merged in the main copy says it landed",
       %{tmp_dir: dir} do
    {repo, git, look} = landed_repo(dir)
    work_branch(repo, git, "story", "s1", "build the thing")
    git.(~w(merge -q --no-ff --no-edit story/s1))

    assert {:ok, said} = look.("s1", "story")
    assert said =~ "landed"
    refute said =~ ~r/stopped|never started/
  end

  test "manager-knows-what-landed: criterion 2 - look at a landed work whose branch was deleted says it landed, from its commits merged in the main copy",
       %{tmp_dir: dir} do
    {repo, git, look} = landed_repo(dir)
    work_branch(repo, git, "story", "s1", "story s1: the story as handed in")
    git.(~w(merge -q --no-ff --no-edit story/s1))
    git.(~w(branch -q -D story/s1))

    assert {:ok, said} = look.("s1", "story")
    assert said =~ "landed"
    refute said =~ ~r/stopped|never started/
  end

  test "manager-knows-what-landed: criterion 3 - look at a work stopped with no checkout says it stopped and why, not that it landed",
       %{tmp_dir: dir} do
    {repo, git, look} = landed_repo(dir)
    # Its branch is not merged: the restart stopped it before it landed.
    work_branch(repo, git, "story", "s2", "story s2: the story as handed in")
    Workflow.Checkout.stop(repo, "s2", "write", "stopped: the service restarted")

    assert {:ok, said} = look.("s2", "story")
    assert said =~ "stopped"
    assert said =~ "the service restarted"
    refute said =~ ~r/landed|never started/
  end

  test "manager-knows-what-landed: criterion 4 - look at a work never started says so, not that it landed or stopped",
       %{tmp_dir: dir} do
    {_repo, git, look} = landed_repo(dir)
    # A branch just cut, with no commits of its own, has not landed.
    git.(~w(branch story/s3))

    assert {:ok, said} = look.("s3", "story")
    assert said =~ "never started"
    refute said =~ ~r/landed|stopped/
  end

  test "manager-knows-what-landed: criterion 5 - a work stopped for good, its file's removal committed in the main copy, is not taken for landed",
       %{tmp_dir: dir} do
    {repo, git, look} = landed_repo(dir)
    File.write!(Path.join(repo, "i1.yml"), "i1\n")
    git.(~w(add -A))
    git.(["commit", "-q", "-m", "issue i1: stopped, its file removed"])
    Workflow.Checkout.cancel(repo, "i1")

    assert {:ok, said} = look.("i1", "issue")
    assert said =~ "stopped for good"
    refute said =~ "landed"
  end
end
