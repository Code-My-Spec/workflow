defmodule Workflow.RouterTest do
  # Not async: the command a checkout runs is swapped for the whole application.
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  @moduletag :tmp_dir

  # The project's copy-setup and copy-teardown, as stand-ins that do nothing.
  defp stand_in_recipes(repo) do
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "justfile"), "copy-setup:\n\ncopy-teardown:\n")
  end

  # Every command a checkout or an own-checkout would run, faked as in Workflow.RunTest.
  defp fake_cmd(dir) do
    test = self()

    Application.put_env(:workflow, :cmd, fn command, args, _call_opts ->
      send(test, {command, args})

      case {command, args} do
        {"git", ["worktree", "add" | _]} -> {"", 0}
        {"git", ["rev-parse", "HEAD^{tree}"]} -> {"t0\n", 0}
        {"git", ["worktree" | _]} -> {"worktree /main copy\nHEAD abc\n", 0}
        {"git", ["rev-parse", "--abbrev-ref", "HEAD"]} -> {"trunk\n", 0}
        {"git", ["rev-list" | _]} -> {"0\n", 0}
        {"git", ["status" | _]} -> {"", 0}
        {"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"]} -> {dir <> "\n", 0}
        {"git", ["rev-parse", "HEAD"]} -> {"c0\n", 0}
        {"git", ["merge" | _]} -> {"", 0}
        {"git", ["remote" | _]} -> {"", 0}
        {"git", ["push" | _]} -> {"", 0}
        {"git", ["log" | _]} -> {"", 0}
        {"just", _args} -> {"", 0}
        {"mix", _args} -> {"", 0}
      end
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)
  end

  defp post_run(body) do
    conn(:post, "/work/run", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Workflow.Router.call(Workflow.Router.init([]))
  end

  # A prod provision handed in and waiting on its owner, with `just` faked to say what it runs.
  defp waiting_prod(dir) do
    fake_cmd(dir)
    test = self()
    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "just", args, _opts ->
        send(test, {:just, args})
        {"", 0}

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    was = Application.get_env(:workflow, :works_dir)
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    on_exit(fn -> Application.put_env(:workflow, :works_dir, was) end)

    File.mkdir_p!(Path.join([dir, "workflow", "provision"]))
    File.write!(Path.join([dir, "workflow", "provision", "prod.steps"]), "a\n")

    work = %{
      "kind" => "provision",
      "id" => "p1",
      "root" => dir,
      "project" => "workflow",
      "target" => "prod"
    }

    assert post_run(work).status == 200
    refute_received {:just, ["provision" | _]}
    work
  end

  @word "the owner's own word"
  @hash Base.encode16(:crypto.hash(:sha256, @word), case: :lower)

  # The go word's hash as config.json would give it at boot, or none.
  defp hold_go(hash) do
    was = Application.fetch_env(:workflow, :go)

    if hash,
      do: Application.put_env(:workflow, :go, hash),
      else: Application.delete_env(:workflow, :go)

    on_exit(fn ->
      case was do
        {:ok, held} -> Application.put_env(:workflow, :go, held)
        :error -> Application.delete_env(:workflow, :go)
      end
    end)
  end

  defp post_go(body) do
    conn(:post, "/work/go", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Workflow.Router.call(Workflow.Router.init([]))
  end

  # The run holds the checkout's lock until it lands: waited out, so it never lands in a later test.
  defp wait_out(work) do
    assert Enum.find(1..500, fn _try ->
             Process.sleep(10)
             not Workflow.Run.look(work).working
           end)
  end

  test "go-needs-the-owners-word: criterion 1 - with no go hash set, the go is refused, says how to set one, and runs nothing",
       %{tmp_dir: dir} do
    work = waiting_prod(dir)
    hold_go(nil)

    conn = post_go(Map.put(work, "word", @word))

    assert conn.status == 403
    assert %{"error" => error} = Jason.decode!(conn.resp_body)
    assert error =~ "\"go\""
    assert error =~ "sha256"
    assert error =~ "config.json"
    refute_receive {:just, ["provision" | _]}, 200
  end

  test "go-needs-the-owners-word: criterion 2 - a wrong word, or none, is refused and runs nothing",
       %{tmp_dir: dir} do
    work = waiting_prod(dir)
    hold_go(@hash)

    assert post_go(Map.put(work, "word", "a guess")).status == 403
    assert post_go(work).status == 403
    refute_receive {:just, ["provision" | _]}, 200
  end

  test "go-needs-the-owners-word: criterion 3 - the owner's word releases the waiting prod provision",
       %{tmp_dir: dir} do
    work = waiting_prod(dir)
    hold_go(@hash)

    conn = post_go(Map.put(work, "word", @word))

    assert conn.status == 200
    assert_receive {:just, ["provision", "a", _dir]}, 2000
    wait_out(work)
  end

  test "go-needs-the-owners-word: criterion 4 - neither the word nor the hash is in any log line or file the loop writes",
       %{tmp_dir: dir} do
    work = waiting_prod(dir)
    hold_go(@hash)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert post_go(Map.put(work, "word", "a guess")).status == 403
        conn = post_go(Map.put(work, "word", @word))
        assert conn.status == 200
        refute conn.resp_body =~ @word
        refute conn.resp_body =~ @hash
        assert_receive {:just, ["provision", "a", _dir]}, 2000
        wait_out(work)
      end)

    refute log =~ @word
    refute log =~ @hash

    written =
      Path.join(dir, "**") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)

    assert written != []

    for file <- written do
      text = File.read!(file)
      refute text =~ @word, "#{file} carries the word"
      refute text =~ @hash, "#{file} carries the hash"
    end
  end

  test "local-api-refuses-foreign-hosts: a foreign Host is refused and does nothing, localhost is served, and a go without the owner's word does not move the work",
       %{tmp_dir: dir} do
    work = waiting_prod(dir)
    # Made up here, at run time: never a real word.
    word = Base.encode16(:crypto.strong_rand_bytes(16))
    hold_go(Base.encode16(:crypto.hash(:sha256, word), case: :lower))

    served = fn url, body ->
      conn(:post, url, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Workflow.LocalOnly.call(Workflow.LocalOnly.init([]))
    end

    # A foreign Host, with or without a port, is refused even with the word.
    for url <- ["http://evil.example/work/go", "http://evil.example:4000/work/go"] do
      conn = served.(url, Map.put(work, "word", word))
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] =~ "Host"
    end

    refute_receive {:just, ["provision" | _]}, 200

    # A localhost go without the owner's word is refused, and the work does not move on.
    assert served.("http://localhost:4000/work/go", work).status == 403
    assert served.("http://localhost/work/go", Map.put(work, "word", "a guess")).status == 403
    refute_receive {:just, ["provision" | _]}, 200
    refute Workflow.Run.look(work).working

    # 127.0.0.1 with the owner's word is served as today.
    assert served.("http://127.0.0.1:4000/work/go", Map.put(work, "word", word)).status == 200
    assert_receive {:just, ["provision", "a", _dir]}, 2000
    wait_out(work)
  end

  test "prod-waits-for-the-owner: POST /work/go from any address but the service's own is refused and runs nothing",
       %{tmp_dir: dir} do
    fake_cmd(dir)
    test = self()
    stand_in = Application.get_env(:workflow, :cmd)

    Application.put_env(:workflow, :cmd, fn
      "just", args, _opts ->
        send(test, {:just, args})
        {"", 0}

      command, args, opts ->
        stand_in.(command, args, opts)
    end)

    work = %{"kind" => "provision", "id" => "p1", "root" => dir, "target" => "prod"}

    conn =
      conn(:post, "/work/go", Jason.encode!(work))
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> put_req_header("content-type", "application/json")
      |> Workflow.Router.call(Workflow.Router.init([]))

    assert conn.status == 403
    refute_received {:just, ["provision" | _]}
    refute File.exists?(Path.join([dir, "workflow", "p1.json"]))
  end

  test "handing in a work that names root still works", %{tmp_dir: dir} do
    fake_cmd(dir)

    conn =
      post_run(%{"kind" => "issue", "id" => "i1", "root" => "/checkout", "project" => "workflow"})

    assert conn.status == 200

    assert %{"done" => false, "step" => "fix", "actor" => "coder"} =
             body = Jason.decode!(conn.resp_body)

    refute Map.has_key?(body, "stopped")
  end

  test "system-steps-outlive-their-caller: POST /work/run answers the path of the work's log at the tree it was handed in at",
       %{tmp_dir: dir} do
    fake_cmd(dir)

    conn = post_run(%{"kind" => "issue", "id" => "i1", "root" => dir, "project" => "workflow"})

    assert conn.status == 200
    log = Path.join([dir, "workflow", "analysis", "t0", "log"])
    assert %{"step" => "fix", "log" => ^log} = Jason.decode!(conn.resp_body)
    assert File.read!(log) =~ "handed in"
  end

  test "no-stalls: criterion 2 - the answer to a work given up on carries stopped", %{
    tmp_dir: dir
  } do
    fake_cmd(dir)

    # An agent named with no key cannot run: the work is given up on as it is handed in.
    {conn, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        post_run(%{
          "kind" => "issue",
          "id" => "i1",
          "root" => "/checkout",
          "agent" => %{"provider" => "anthropic"}
        })
      end)

    assert conn.status == 200

    assert %{"stopped" => %{"step" => "fix", "reason" => reason, "at" => _}} =
             Jason.decode!(conn.resp_body)

    assert reason =~ "not started"
  end

  test "no-stalls: criterion 2 - GET /works/:id carries stopped", %{tmp_dir: dir} do
    fake_cmd(dir)
    Workflow.Checkout.stop("/checkout", "i1", "fix", "gave up")

    conn =
      conn(:get, "/works/i1?kind=issue&root=/checkout")
      |> Workflow.Router.call(Workflow.Router.init([]))

    assert conn.status == 200

    assert %{"stopped" => %{"step" => "fix", "reason" => "gave up"}} =
             Jason.decode!(conn.resp_body)
  end

  test "handing in a work that names a repo cuts a checkout for it and runs with it", %{
    tmp_dir: dir
  } do
    fake_cmd(dir)
    repo = Path.join(dir, "myrepo")
    was = Application.get_env(:workflow, :works_dir)
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    on_exit(fn -> Application.put_env(:workflow, :works_dir, was) end)

    conn = post_run(%{"kind" => "issue", "id" => "i1", "repo" => repo, "project" => "workflow"})

    # The copy is made as the work's first step, after the hand-in answers.
    assert conn.status == 200

    assert %{"done" => false, "step" => "copy-setup", "agent" => "started"} =
             Jason.decode!(conn.resp_body)

    assert_receive {"git", ["worktree", "add" | _]}, 2_000

    # Left on fix with no agent named: no longer in flight once the copy is made.
    assert Enum.find(1..500, fn _try ->
             Process.sleep(10)
             not File.exists?(Path.join([dir, "works", "i1.json"]))
           end)
  end

  test "a work naming neither root nor repo is refused", %{tmp_dir: dir} do
    fake_cmd(dir)

    conn = post_run(%{"kind" => "issue", "id" => "i1"})

    assert conn.status == 422
  end

  defp post_say(body) do
    conn(:post, "/work/say", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Workflow.Router.call(Workflow.Router.init([]))
  end

  test "say-to-a-work: criterion 1 - what is said to a work reaches its next agent turn, whichever agent, under a line from the owner",
       %{tmp_dir: dir} do
    fake_cmd(dir)
    work = %{"kind" => "issue", "id" => "i1", "root" => dir, "text" => "Fix it."}
    Workflow.Checkout.keep(dir, "i1", work)

    coder = %{name: "fix", actor: :coder, note: "Fix it.", agent: %{}}
    reviewer = %{name: "review", actor: :reviewer, note: "Review it.", agent: %{decides: true}}

    for {step, said} <- [{coder, "use the retry helper"}, {reviewer, "mind the migration"}] do
      conn = post_say(%{"id" => "i1", "root" => dir, "say" => said})
      assert conn.status == 200

      message = Workflow.Agents.message(step, work, [])

      assert message =~ said
      assert message =~ ~r/from the work's owner/i
    end
  end

  test "say-to-a-work: criterion 4 - POST /work/say for a work with no checkout answers 404", %{
    tmp_dir: dir
  } do
    fake_cmd(dir)

    conn = post_say(%{"id" => "i9", "repo" => Path.join(dir, "nowhere"), "say" => "hello"})

    assert conn.status == 404
    assert %{"error" => "that work has no checkout"} = Jason.decode!(conn.resp_body)

    conn = post_say(%{"id" => "i9", "root" => Path.join(dir, "nowhere"), "say" => "hello"})

    assert conn.status == 404
    assert %{"error" => "that work has no checkout"} = Jason.decode!(conn.resp_body)
  end

  test "say-to-a-work: criterion 2 - when several things are said before a turn, its message holds all of them",
       %{tmp_dir: dir} do
    fake_cmd(dir)
    work = %{"kind" => "issue", "id" => "i1", "root" => dir, "text" => "Fix it."}
    Workflow.Checkout.keep(dir, "i1", work)
    coder = %{name: "fix", actor: :coder, note: "Fix it.", agent: %{}}

    said = ["use the retry helper", "leave the schema alone", "add a test for nil titles"]

    for each <- said do
      assert post_say(%{"id" => "i1", "root" => dir, "say" => each}).status == 200
    end

    message = Workflow.Agents.message(coder, work, [])

    for each <- said, do: assert(message =~ each)
  end

  test "say-to-a-work: criterion 3 - what was said appears in one turn only, the turn after does not include it",
       %{tmp_dir: dir} do
    fake_cmd(dir)
    work = %{"kind" => "issue", "id" => "i1", "root" => dir, "text" => "Fix it."}
    Workflow.Checkout.keep(dir, "i1", work)
    coder = %{name: "fix", actor: :coder, note: "Fix it.", agent: %{}}

    assert post_say(%{"id" => "i1", "root" => dir, "say" => "use the retry helper"}).status ==
             200

    assert Workflow.Agents.message(coder, work, []) =~ "use the retry helper"

    after_turn = Workflow.Agents.message(coder, work, [])

    refute after_turn =~ "use the retry helper"
    refute after_turn =~ ~r/from the work's owner/i
    # What was said is kept beside the work, never over it.
    assert Workflow.Checkout.kept(dir, "i1") == work
  end

  defp post_mcp(body) do
    conn(:post, "/mcp", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> Workflow.Router.call(Workflow.Router.init([]))
  end

  test "mcp-say: criterion 1 - initialize answers a JSON-RPC result naming the server and declaring tools; a notification answers 202 with no body" do
    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0"}
        }
      })

    assert conn.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "serverInfo" => %{"name" => "" <> _name},
               "capabilities" => %{"tools" => %{}}
             }
           } = Jason.decode!(conn.resp_body)

    notified = post_mcp(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    assert notified.status == 202
    assert notified.resp_body == ""
  end

  test "mcp-say: criterion 2 - tools/list answers exactly one tool, say, taking one required string argument, say" do
    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    assert conn.status == 200

    # say, and beside it (messages criterion 4) inbox.
    assert %{"jsonrpc" => "2.0", "id" => 2, "result" => %{"tools" => tools}} =
             Jason.decode!(conn.resp_body)

    assert tool = Enum.find(tools, &(&1["name"] == "say"))
    assert %{"type" => "object"} = schema = tool["inputSchema"]
    # say is the one required argument; to and from (messages criterion 3) are optional.
    assert %{"say" => %{"type" => "string"}} = schema["properties"]
    assert Map.keys(schema["properties"]) -- ["to", "from"] == ["say"]
    assert schema["required"] == ["say"]
  end

  test "chat-interview: criterion 1 - tools/list says to ask questions before passing a request on, until it knows who it is for, what they should be able to do, and two to four things that would show it works" do
    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert %{"result" => %{"tools" => [%{"name" => "say", "description" => description} | _]}} =
             Jason.decode!(conn.resp_body)

    text = String.downcase(description)

    assert text =~ "ask"
    assert text =~ "question"
    assert text =~ "before"
    assert text =~ "who"
    assert text =~ "should be able to do"
    assert text =~ "two to four"
    assert text =~ "works"
  end

  test "chat-interview: criterion 2 - the say description says to pass on the settled request in the person's own words with the answers, and never to invent answers" do
    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert %{"result" => %{"tools" => [%{"name" => "say", "description" => description} | _]}} =
             Jason.decode!(conn.resp_body)

    text = String.downcase(description)

    assert text =~ "settled request"
    assert text =~ "own words"
    assert text =~ "answers"
    assert text =~ "never invent"
  end

  test "chat-interview: criterion 3 - the say description says a plain question about status goes straight through with no interview" do
    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert %{"result" => %{"tools" => [%{"name" => "say", "description" => description} | _]}} =
             Jason.decode!(conn.resp_body)

    text = String.downcase(description)

    assert text =~ "question about what is running, waiting, done or stopped"
    assert text =~ "straight through"
    assert text =~ "no questions first"
  end

  test "mcp-say: criterion 3 - tools/call of say with a manager configured answers, as the tool's text, what POST /manager would answer",
       %{tmp_dir: dir} do
    was = for key <- [:manager, :works_dir], do: {key, Application.get_env(:workflow, key)}

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      {:ok, %{text: "heard: " <> message, messages: opts[:messages]}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :manager_run)

      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    words = "saving with no title crashes"

    manager =
      conn(:post, "/manager", Jason.encode!(%{say: words}))
      |> put_req_header("content-type", "application/json")
      |> Workflow.Router.call(Workflow.Router.init([]))

    assert manager.status == 200
    assert %{"said" => "" <> said} = Jason.decode!(manager.resp_body)
    assert said == "heard: " <> words

    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "say", "arguments" => %{"say" => words}}
      })

    assert conn.status == 200

    assert %{"jsonrpc" => "2.0", "id" => 3, "result" => %{"content" => [content]}} =
             Jason.decode!(conn.resp_body)

    assert content == %{"type" => "text", "text" => said}
  end

  test "mcp-say: criterion 4 - tools/call of say with no manager configured answers an MCP error result, and the service keeps answering" do
    was = Application.get_env(:workflow, :manager)
    Application.delete_env(:workflow, :manager)

    on_exit(fn ->
      if was,
        do: Application.put_env(:workflow, :manager, was),
        else: Application.delete_env(:workflow, :manager)
    end)

    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "say", "arguments" => %{"say" => "hello"}}
      })

    assert conn.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 4,
             "result" => %{
               "isError" => true,
               "content" => [%{"type" => "text", "text" => "" <> _}]
             }
           } = Jason.decode!(conn.resp_body)

    # The service keeps answering.
    again = post_mcp(%{"jsonrpc" => "2.0", "id" => 5, "method" => "tools/list"})

    assert again.status == 200
    assert %{"result" => %{"tools" => tools}} = Jason.decode!(again.resp_body)
    assert Enum.any?(tools, &(&1["name"] == "say"))
  end

  test "messages: criterion 1 - a message is appended to inbox/<to>.jsonl beside the works directory before delivery, and a failed delivery leaves it there and is reported in the answer, not raised",
       %{tmp_dir: dir} do
    was = for key <- [:recipients, :works_dir], do: {key, Application.get_env(:workflow, key)}

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    # A claude-code recipient whose session socket is not there: delivery must fail.
    Application.put_env(:workflow, :recipients, %{
      "alice" => %{"kind" => "claude-code", "socket" => Path.join(dir, "no-such-session.sock")}
    })

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 9,
        "method" => "tools/call",
        "params" => %{
          "name" => "say",
          "arguments" => %{"to" => "alice", "from" => "bob", "say" => "are you there"}
        }
      })

    # Reported in the answer, never raised.
    assert conn.status == 200

    assert %{
             "id" => 9,
             "result" => %{"isError" => true, "content" => [%{"text" => "" <> answer}]}
           } = Jason.decode!(conn.resp_body)

    assert answer =~ ~r/kept/i
    assert answer =~ ~r/delivery failed/i

    # Kept: one JSON line in the recipient's inbox, beside the works directory.
    inbox = Path.join([dir, "inbox", "alice.jsonl"])
    assert File.regular?(inbox)

    assert [line] = inbox |> File.read!() |> String.split("\n", trim: true)

    assert %{"to" => "alice", "from" => "bob", "text" => "are you there"} = Jason.decode!(line)
  end

  test "messages: criterion 2 - delivery follows the recipient's kind: a service-run recipient answers in the same call, claude-code gets one user message on its socket, codex is queued, chat gets nothing pushed",
       %{tmp_dir: dir} do
    test = self()

    keys = [
      :recipients,
      :works_dir,
      :manager,
      :manager_run,
      :connect,
      :cmd,
      :codex_command,
      :claude_config_dir
    ]

    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :claude_config_dir, Path.join(dir, "claude"))
    Application.delete_env(:workflow, :codex_command)

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      {:ok, %{text: "heard: " <> message, messages: opts[:messages]}}
    end)

    # A local listener stands in for the session socket.
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    Application.put_env(:workflow, :connect, fn socket ->
      send(test, {:connected, socket})
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    end)

    Application.put_env(:workflow, :cmd, fn command, args, _opts ->
      send(test, {:cmd, command, args})
      {"", 0}
    end)

    Application.put_env(:workflow, :recipients, %{
      "pm" => %{"kind" => "service"},
      "cc" => %{"kind" => "claude-code", "socket" => "/sessions/cc.sock"},
      "cx" => %{"kind" => "codex", "thread" => "t-1"},
      "ch" => %{"kind" => "chat"}
    })

    # A service-run recipient: its next turn, and its answer in the same call.
    assert {:ok, "heard: hello pm"} = Workflow.Messages.say("pm", "bob", "hello pm")
    refute_received {:connected, _socket}
    refute_received {:cmd, _command, _args}

    # claude-code: one user message on its session socket.
    assert {:ok, _answer} = Workflow.Messages.say("cc", "bob", "hello cc")
    assert_received {:connected, "/sessions/cc.sock"}
    {:ok, server} = :gen_tcp.accept(listener, 1_000)
    {:ok, data} = :gen_tcp.recv(server, 0, 1_000)

    assert [%{"type" => "user", "message" => %{"role" => "user", "content" => "hello cc"}}] =
             data |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    refute_received {:cmd, _command, _args}

    # codex: queued with `codex queue --thread <thread> --message <text>`.
    assert {:ok, _answer} = Workflow.Messages.say("cx", "bob", "hello cx")
    assert_received {:cmd, "codex", ["queue", "--thread", "t-1", "--message", "hello cx"]}
    refute_received {:connected, _socket}

    # chat: nothing pushed.
    assert {:ok, _answer} = Workflow.Messages.say("ch", "bob", "hello ch")
    refute_received {:connected, _socket}
    refute_received {:cmd, _command, _args}

    :gen_tcp.close(listener)
  end

  test "messages: criterion 3 - on POST /mcp say takes an optional to (default the manager) and from (default chat), and for a claude-code or codex recipient answers at once that it was delivered and the reply will be in the inbox",
       %{tmp_dir: dir} do
    test = self()
    keys = [:recipients, :works_dir, :manager, :manager_run, :connect, :cmd, :codex_command]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.delete_env(:workflow, :codex_command)

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      {:ok, %{text: "heard: " <> message, messages: opts[:messages]}}
    end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    Application.put_env(:workflow, :connect, fn _socket ->
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    end)

    Application.put_env(:workflow, :cmd, fn command, args, _opts ->
      send(test, {:cmd, command, args})
      {"", 0}
    end)

    Application.put_env(:workflow, :recipients, %{
      "cc" => %{"kind" => "claude-code", "socket" => "/sessions/cc.sock"},
      "cx" => %{"kind" => "codex", "thread" => "t-1"}
    })

    # The tool declares both optional arguments; only say is required.
    listed = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert %{"result" => %{"tools" => tools}} = Jason.decode!(listed.resp_body)
    say = Enum.find(tools, &(&1["name"] == "say"))

    assert %{"to" => %{"type" => "string"}, "from" => %{"type" => "string"}} =
             say["inputSchema"]["properties"]

    assert say["inputSchema"]["required"] == ["say"]

    call = fn id, arguments ->
      conn =
        post_mcp(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "tools/call",
          "params" => %{"name" => "say", "arguments" => arguments}
        })

      assert conn.status == 200
      Jason.decode!(conn.resp_body)
    end

    # Neither given: to the manager, from chat; the manager's own answer comes back.
    assert %{"result" => %{"content" => [%{"text" => "heard: hi"}]} = plain} =
             call.(2, %{"say" => "hi"})

    refute plain["result"]["isError"]

    assert [%{"to" => "manager", "from" => "chat", "text" => "hi"}] =
             Workflow.Messages.unread("manager")

    # claude-code and codex: answered at once, delivered, the reply to be in the inbox.
    for {id, to} <- [{3, "cc"}, {4, "cx"}] do
      assert %{"result" => %{"content" => [%{"text" => answer}]} = result} =
               call.(id, %{"say" => "hello", "to" => to, "from" => "bob"})

      refute result["result"]["isError"]
      assert answer =~ ~r/delivered/i
      assert answer =~ ~r/reply will be in the inbox/i
    end

    assert_received {:cmd, "codex", ["queue", "--thread", "t-1", "--message", "hello"]}
    :gen_tcp.close(listener)
  end

  test "messages: criterion 4 - on POST /mcp the inbox tool answers the messages kept for a name (default chat) since it last asked, and marks them read so a second call does not return them again",
       %{tmp_dir: dir} do
    keys = [:recipients, :works_dir]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :recipients, %{"chat" => %{"kind" => "chat"}})

    # Listed beside say, so a chat model can find it: an optional name, nothing required.
    listed = post_mcp(%{"jsonrpc" => "2.0", "id" => 0, "method" => "tools/list"})
    assert %{"result" => %{"tools" => tools}} = Jason.decode!(listed.resp_body)
    assert inbox = Enum.find(tools, &(&1["name"] == "inbox"))
    assert %{"name" => %{"type" => "string"}} = inbox["inputSchema"]["properties"]
    assert inbox["inputSchema"]["required"] in [nil, []]

    call = fn id, name, arguments ->
      conn =
        post_mcp(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "tools/call",
          "params" => %{"name" => name, "arguments" => arguments}
        })

      assert conn.status == 200

      assert %{"id" => ^id, "result" => %{"content" => [%{"text" => text}]} = result} =
               Jason.decode!(conn.resp_body)

      refute result["result"]["isError"]
      Jason.decode!(text)
    end

    say = fn id, to, text ->
      call_say =
        post_mcp(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "tools/call",
          "params" => %{
            "name" => "say",
            "arguments" => %{"to" => to, "from" => "bob", "say" => text}
          }
        })

      assert call_say.status == 200
    end

    say.(1, "chat", "first")
    say.(2, "chat", "second")
    say.(3, "other", "not for chat")

    # No name given: chat's, all of what was kept for it.
    assert [
             %{"to" => "chat", "from" => "bob", "text" => "first"},
             %{"to" => "chat", "from" => "bob", "text" => "second"}
           ] = call.(4, "inbox", %{})

    # Marked read: a second call does not return them again.
    assert [] = call.(5, "inbox", %{})

    # Only what came after is returned next time.
    say.(6, "chat", "third")
    assert [%{"text" => "third"}] = call.(7, "inbox", %{})

    # Another name has its own inbox, and its own mark.
    assert [%{"to" => "other", "text" => "not for chat"}] =
             call.(8, "inbox", %{"name" => "other"})

    assert [] = call.(9, "inbox", %{"name" => "other"})
  end

  test "manager-tools: criterion 1 - POST /mcp/manager lists hand_in, decide and look, plus say and inbox" do
    was = Application.get_env(:workflow, :manager)

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => "/nowhere/repo"
    })

    on_exit(fn ->
      if was,
        do: Application.put_env(:workflow, :manager, was),
        else: Application.delete_env(:workflow, :manager)
    end)

    conn =
      conn(
        :post,
        "/mcp/manager",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> Workflow.Router.call(Workflow.Router.init([]))

    assert conn.status == 200

    assert %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => tools}} =
             Jason.decode!(conn.resp_body)

    names = tools |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["decide", "hand_in", "inbox", "look", "record", "say", "stop", "tell"]

    for tool <- tools do
      assert %{"type" => "object"} = tool["inputSchema"]
    end

    # The same inputs the service-run manager's tools take: the same definitions.
    own = Map.new(Workflow.Manager.tools(Workflow.Manager.configured()), &{&1.name, &1})

    for tool <- tools, own[tool["name"]] do
      assert tool["inputSchema"] ==
               own[tool["name"]].input_schema |> Jason.encode!() |> Jason.decode!()
    end
  end

  # Puts each setting for the test only, putting back what was there after.
  defp settings(settings) do
    was = for {key, _value} <- settings, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    for {key, value} <- settings do
      if value,
        do: Application.put_env(:workflow, key, value),
        else: Application.delete_env(:workflow, key)
    end
  end

  defp post_to(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Workflow.Router.call(Workflow.Router.init([]))
  end

  defp call_tool(path, id, name, arguments) do
    conn =
      post_to(path, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  test "manager-tools: criterion 2 - with no manager settings POST /mcp/manager answers 404" do
    settings(manager: nil)

    conn = post_to("/mcp/manager", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    assert conn.status == 404
  end

  test "manager-tools: criterion 3 - POST /mcp keeps offering only say and inbox, and refuses any other tool as unknown",
       %{tmp_dir: dir} do
    settings(
      manager: %{"agent" => %{"provider" => "claude-code"}, "repo" => dir, "cap" => 0},
      works_dir: Path.join(dir, "works")
    )

    listed = post_to("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    assert %{"result" => %{"tools" => tools}} = Jason.decode!(listed.resp_body)
    assert tools |> Enum.map(& &1["name"]) |> Enum.sort() == ["inbox", "say"]

    for name <- ["hand_in", "decide", "look", "nothing"] do
      assert %{"id" => 2, "error" => %{"message" => message}} =
               call_tool("/mcp", 2, name, %{"id" => "x1", "kind" => "issue"})

      assert message =~ "unknown tool #{name}"
    end
  end

  test "manager-tools: criterion 4 - on POST /mcp/manager the manager's tools answer what the service-run manager's answer, with its repo and cap",
       %{tmp_dir: dir} do
    settings(
      manager: %{"agent" => %{"provider" => "claude-code"}, "repo" => dir, "cap" => 0},
      works_dir: Path.join(dir, "works")
    )

    own = Map.new(Workflow.Manager.tools(Workflow.Manager.configured()), &{&1.name, &1})

    for {name, arguments} <- [
          {"look", %{"id" => "x1", "kind" => "issue"}},
          {"hand_in", %{"id" => "x2", "kind" => "issue", "text" => "broken"}}
        ] do
      {:ok, expected} = own[name].execute.(arguments, %{})

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => ^expected}]} = result} =
               call_tool("/mcp/manager", 3, name, arguments)

      refute result["isError"]
    end

    # Looked for in the checkout beside the configured repo; refused by the configured cap.
    assert %{"result" => %{"content" => [%{"text" => "There is no checkout for x1." <> _}]}} =
             call_tool("/mcp/manager", 4, "look", %{"id" => "x1", "kind" => "issue"})

    assert %{"result" => %{"content" => [%{"text" => "Refused: " <> _}]}} =
             call_tool("/mcp/manager", 5, "hand_in", %{"id" => "x2", "kind" => "issue"})

    # Arguments a tool cannot take are an error result, and the service keeps answering.
    assert %{"result" => %{"isError" => true}} = call_tool("/mcp/manager", 6, "look", %{})
  end

  test "tell: on POST /mcp/manager the manager's tell keeps what is said for a running work's next turn, and says plainly when there is no such work",
       %{tmp_dir: dir} do
    fake_cmd(dir)
    repo = Path.join(dir, "repo")
    settings(manager: %{"repo" => repo}, works_dir: Path.join(dir, "works"))
    root = Workflow.Checkout.root(repo, "i1")
    File.mkdir_p!(root)
    Workflow.Checkout.keep(root, "i1", %{"kind" => "issue", "id" => "i1", "text" => "Fix it."})

    assert %{"result" => %{"content" => [%{"text" => "i1: told."}]} = result} =
             call_tool("/mcp/manager", 1, "tell", %{"id" => "i1", "say" => "use the helper"})

    refute result["isError"]
    assert Workflow.Checkout.heard(root, "i1") == ["use the helper"]

    assert %{"result" => %{"content" => [%{"text" => "There is no work i9 running."}]}} =
             call_tool("/mcp/manager", 2, "tell", %{"id" => "i9", "say" => "hello"})

    refute File.exists?(Workflow.Checkout.root(repo, "i9"))
  end

  test "manager-tools: criterion 5 - manager settings with a repo and no agent boot, POST /mcp/manager works, and a say to the manager is delivered by its recipient kind without running a turn",
       %{tmp_dir: dir} do
    test = self()

    settings(
      manager: nil,
      recipients: nil,
      works_dir: Path.join(dir, "works"),
      manager_run: fn _text, _opts -> send(test, :turn_run) end,
      cmd: fn command, args, _opts ->
        send(test, {:cmd, command, args})
        {"", 0}
      end
    )

    File.write!(
      Path.join(dir, "config.json"),
      Jason.encode!(%{"manager" => %{"repo" => Path.join(dir, "repo")}})
    )

    assert :ok = Workflow.ConfigFile.load()
    assert %{"repo" => _} = Workflow.Manager.configured()

    listed = post_to("/mcp/manager", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    assert listed.status == 200
    assert %{"result" => %{"tools" => [_, _, _, _, _, _, _, _]}} = Jason.decode!(listed.resp_body)

    # No recipient named manager: an inbox, read by whoever acts as the manager.
    assert %{"result" => %{"content" => [%{"text" => kept}]} = result} =
             call_tool("/mcp/manager", 2, "say", %{"say" => "build a thing"})

    refute result["isError"]
    assert kept =~ "inbox"
    refute_received :turn_run

    assert [%{"to" => "manager", "from" => "chat", "text" => "build a thing"}] =
             Jason.decode!(
               hd(
                 call_tool("/mcp/manager", 3, "inbox", %{"name" => "manager"})["result"][
                   "content"
                 ]
               )[
                 "text"
               ]
             )

    # A recipient named manager is delivered to by its kind: codex is queued.
    Application.put_env(:workflow, :recipients, %{
      "manager" => %{"kind" => "codex", "thread" => "t-9"}
    })

    assert %{"result" => %{"content" => [%{"text" => delivered}]}} =
             call_tool("/mcp", 4, "say", %{"say" => "hello pm"})

    assert delivered =~ ~r/delivered/i
    assert_received {:cmd, "codex", ["queue", "--thread", "t-9", "--message", "hello pm"]}
    refute_received :turn_run
  end

  test "manager-tools: criterion 6 - a manager session needs no agent of the service's: with settings naming a repo and no agent, POST /mcp/manager works and a say to the manager is delivered by its recipient kind, not a turn",
       %{tmp_dir: dir} do
    test = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    settings(
      manager: %{"repo" => Path.join(dir, "repo")},
      recipients: %{
        "manager" => %{"kind" => "claude-code", "socket" => "/sessions/manager.sock"}
      },
      works_dir: Path.join(dir, "works"),
      claude_config_dir: Path.join(dir, "claude"),
      manager_run: fn _text, _opts -> send(test, :turn_run) end,
      connect: fn _socket -> :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false]) end
    )

    refute Map.has_key?(Workflow.Manager.configured(), "agent")

    # The manager's tools are offered with no agent to run turns on.
    listed = post_to("/mcp/manager", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    assert listed.status == 200
    assert %{"result" => %{"tools" => tools}} = Jason.decode!(listed.resp_body)

    assert tools |> Enum.map(& &1["name"]) |> Enum.sort() ==
             ~w(decide hand_in inbox look record say stop tell)

    # A say to the manager is delivered by its recipient kind: one user message on its socket.
    assert %{"result" => %{"content" => [%{"text" => answer}]} = result} =
             call_tool("/mcp/manager", 2, "say", %{"say" => "build a thing"})

    refute result["isError"]
    assert answer =~ ~r/delivered/i

    {:ok, server} = :gen_tcp.accept(listener, 1_000)
    {:ok, data} = :gen_tcp.recv(server, 0, 1_000)

    assert [%{"type" => "user", "message" => %{"content" => "build a thing"}}] =
             data |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    refute_received :turn_run
    :gen_tcp.close(listener)
  end

  test "manager-tools: criterion 7 - a story handed in on POST /mcp/manager starts the work as the service-run manager's hand_in does, with the repo, project, cap and agents from the manager settings",
       %{tmp_dir: dir} do
    test = self()
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

    settings(
      manager: %{
        "agent" => %{"provider" => "claude-code"},
        "repo" => repo,
        "project" => "proj",
        "agents" => agents,
        "cap" => 5
      },
      works_dir: Path.join(dir, "works"),
      # Each agent's turn is held, so nothing real runs and the work stays in flight.
      agents_run: fn _step, work ->
        send(test, {:agent, work})
        receive do: (:never -> {%{}, nil})
      end,
      manager_run: fn _text, _opts -> send(test, :turn_run) end
    )

    story = fn id ->
      %{
        "kind" => "story",
        "id" => id,
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
        ]
      }
    end

    assert %{"result" => %{"content" => [%{"type" => "text", "text" => answer}]} = result} =
             call_tool("/mcp/manager", 1, "hand_in", story.("s1"))

    refute result["isError"]

    # Started: in flight under works_dir, cut beside the configured repo, and run
    # with the configured project and agents.
    assert_receive {:agent, %{"id" => "s1"} = work}, 5_000
    assert %{"repo" => ^repo, "project" => "proj", "agents" => ^agents} = work
    assert Map.take(work, Map.keys(story.("s1"))) == story.("s1")
    assert File.exists?(Path.join([dir, "works", "s1.json"]))
    assert File.dir?(repo <> "-s1")

    assert File.read!(Path.join([repo <> "-s1", "proj", "stories", "s1.yml"])) =~
             "title: Invite a teammate"

    # The service-run manager's own hand_in answers the same for the same input.
    hand_in =
      Enum.find(Workflow.Manager.tools(Workflow.Manager.configured()), &(&1.name == "hand_in"))

    assert {:ok, own} = hand_in.execute.(story.("s2"), %{})
    assert_receive {:agent, %{"id" => "s2"}}, 5_000
    # Each answers its own work's log, at the tree its own story file made.
    unlogged = &String.replace(&1, ~r/ Its log: .+\/log$/, "")
    assert unlogged.(answer) == String.replace(unlogged.(own), "s2", "s1")
    assert answer =~ ~r/^s1: on /

    refute_received :turn_run
  end

  test "inbox-trailer: criterion 1 - every answer a tool gives on POST /mcp ends with a line saying how many unread messages are in the chat's inbox: with two unread, the answer to a say ends with a line saying 2 messages are in your inbox",
       %{tmp_dir: dir} do
    keys = [:recipients, :works_dir]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :recipients, %{"chat" => %{"kind" => "chat"}})

    # Two messages kept for the chat, unread.
    assert {:ok, _} = Workflow.Messages.say("chat", "bob", "first")
    assert {:ok, _} = Workflow.Messages.say("chat", "bob", "second")

    # A say to someone else: its answer still tells the chat what is waiting.
    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "say",
          "arguments" => %{"to" => "other", "from" => "chat", "say" => "hello"}
        }
      })

    assert conn.status == 200

    assert %{"id" => 1, "result" => %{"content" => [%{"text" => text}]}} =
             Jason.decode!(conn.resp_body)

    last = text |> String.split("\n", trim: true) |> List.last()
    assert last =~ ~r/\b2 messages are in your inbox/
  end

  # The chat's inbox kept under `dir`, with the chat a plain inbox.
  defp chat_inbox(dir) do
    keys = [:recipients, :works_dir]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :recipients, %{"chat" => %{"kind" => "chat"}})
  end

  defp call_tool(id, name, arguments) do
    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    assert conn.status == 200

    assert %{"id" => ^id, "result" => %{"content" => [%{"text" => text}]}} =
             Jason.decode!(conn.resp_body)

    text
  end

  test "inbox-trailer: criterion 2 - with no unread messages, the answer to a tool has no inbox line",
       %{tmp_dir: dir} do
    chat_inbox(dir)

    text = call_tool(1, "say", %{"to" => "other", "from" => "chat", "say" => "hello"})
    assert text == "Kept in other's inbox; nothing is pushed to other."
    refute text =~ "inbox.\n"
    refute text =~ ~r/messages? (is|are) in your inbox/
  end

  test "inbox-trailer: one unread message is told in the singular", %{tmp_dir: dir} do
    chat_inbox(dir)
    assert {:ok, _} = Workflow.Messages.say("chat", "bob", "only")

    text = call_tool(1, "say", %{"to" => "other", "from" => "chat", "say" => "hello"})
    assert text |> String.split("\n", trim: true) |> List.last() == "1 message is in your inbox."
  end

  test "inbox-trailer: criterion 3 - the answer to inbox itself has no inbox line, since it has just read them",
       %{tmp_dir: dir} do
    chat_inbox(dir)
    assert {:ok, _} = Workflow.Messages.say("chat", "bob", "first")
    assert {:ok, _} = Workflow.Messages.say("chat", "bob", "second")

    text = call_tool(1, "inbox", %{})
    refute text =~ "in your inbox"
    assert [%{"text" => "first"}, %{"text" => "second"}] = Jason.decode!(text)

    text = call_tool(2, "say", %{"to" => "other", "from" => "chat", "say" => "hello"})
    refute text =~ "in your inbox"
  end

  test "inbox-trailer: criterion 4 - a question is just a message: a message to the chat beginning \"Ask the user:\" is kept and read like any other, with no extra field or tool",
       %{tmp_dir: dir} do
    chat_inbox(dir)

    text =
      call_tool(1, "say", %{"to" => "chat", "from" => "manager", "say" => "Ask the user: which?"})

    assert text |> String.split("\n", trim: true) |> List.last() == "1 message is in your inbox."

    assert [message] = Jason.decode!(call_tool(2, "inbox", %{}))
    assert message == %{"to" => "chat", "from" => "manager", "text" => "Ask the user: which?"}
  end

  test "inbox-trailer: the say tool's description says to read the inbox on the line and to put questions to the person" do
    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    %{"result" => %{"tools" => tools}} = Jason.decode!(conn.resp_body)
    %{"description" => description} = Enum.find(tools, &(&1["name"] == "say"))

    assert description =~ "messages are in your inbox, read your inbox"
    assert description =~ ~s(begins "Ask the user:" to the person)
  end
end
