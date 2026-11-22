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
             "message_chat",
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

    # The story already in the main copy, as a person or another tool wrote it.
    file =
      Path.join(
        repo,
        Workflow.StoryFile.path(Map.merge(story, %{"kind" => "story", "project" => "proj"}))
      )

    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Workflow.StoryFile.yaml(Map.put(story, "kind", "story")))
    git.(repo, ~w(add -A))
    git.(repo, ["commit", "-m", "story s1: Invite a teammate"])

    # Handed in by its id alone.
    assert {:ok, _said} = hand_in.execute.(%{"kind" => "story", "id" => "s1"}, %{})
    assert_receive {:agent, _agent, work}, 5_000

    assert work["title"] == "Invite a teammate"
    assert work["rules"] == rules
    assert work["criteria"] |> List.wrap() |> length() == 2

    # The work's checkout holds the one story commit, the main copy's.
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

    assert changed == ["proj/stories/s1.yml"]

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
      Jason.encode!(%{
        "work" => kept,
        # Its ci already in, so the journey lands done once it is promoted.
        "t1" => %{
          "review" => %{"status" => "pass"},
          "ci" => %{"event" => "ci", "verdict" => "green"}
        }
      })
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

    # The killed agent's work is stopped and the manager told so. With i1's turn
    # gone every run ends by itself, so all are waited on, not on a clock, and no
    # telling lands in the next test's manager.
    capture_log(fn ->
      Process.exit(agent, :kill)
      Workflow.Settled.idle()
    end)

    # Its promote is the system's, run after decide answers.
    assert_received {"git", ["merge", "--no-ff", "--no-edit", "c1"]}

    # Its landing tells the manager in the background.
    assert_received {:told, "journey j1: " <> _}
    assert_received {:told, "issue i1: stopped" <> _}
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

  test "landed-means-merged: criterion 1 - a work whose only commit on main is its issue as handed in has not landed; criterion 2 - once its branch merges it has",
       %{tmp_dir: dir} do
    {repo, git, _look} = landed_repo(dir)
    File.write!(Path.join(repo, "i1.yml"), "i1\n")
    git.(~w(add -A))
    git.(["commit", "-q", "-m", "issue i1: the issue as handed in"])
    work_branch(repo, git, "issue", "i1", "i1: the fix")

    refute Workflow.Checkout.landed?(repo, "issue", "i1")

    git.(~w(merge -q --no-ff --no-edit issue/i1))
    assert Workflow.Checkout.landed?(repo, "issue", "i1")
  end

  test "decide-refuses-unknown-id: decide with an id no work is waiting under is refused, naming it, and starts nothing",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    configure(Map.put(@manager, "repo", repo), dir)
    test = self()

    # Every command is told to the test; a checkout asked for is made, as git would.
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

        _other ->
          {"", 0}
      end
    end)

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:agent, work})
      {%{}, nil}
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      for key <- [:cmd, :agents_run, :manager_run], do: Application.delete_env(:workflow, key)
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    decide = Enum.find(tools, &(&1.name == "decide"))

    capture_log(fn ->
      assert {:ok, said} =
               decide.execute.(%{"id" => "ghost", "kind" => "issue", "demo" => "approve"}, %{})

      send(test, {:said, said})
      refute_receive {:agent, _work}, 500
    end)

    assert_received {:said, said}
    assert said =~ "Refused"
    assert said =~ "ghost"

    # No checkout, branch or commit asked of git, and no works, story or issue file made.
    refute_received {"git", ["worktree", "add" | _]}
    refute_received {"git", ["branch" | _]}
    refute_received {"git", ["commit" | _]}
    refute File.exists?(repo <> "-ghost")
    refute File.exists?(Path.join(dir, "works"))
    assert Path.wildcard(Path.join(dir, "**/*ghost*"), match_dot: true) == []
  end
end
