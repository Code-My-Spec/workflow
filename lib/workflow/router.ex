defmodule Workflow.Router do
  @moduledoc """
  The one call that hands a piece of work in.

      POST /work/run
      {"kind": "issue", "id": "demo-1", "root": "/path/to/checkout",
       "text": "Saving with no title crashes.",
       "project": "workflow",
       "agent": {"provider": "claude-code", "model": "claude-sonnet-5-5"},
       "agents": {"reviewer": {"provider": "claude-code", "model": "claude-opus-5"}}}

  Names its checkout by `"root"`, or by a `"repo"` for one cut fresh beside it
  and taken away once the work is done.

  It runs what the system can and answers the step the work is left on. Given an
  agent, an agent's step is handed to it and the work carries on by itself:
  see `Workflow.Run`. A review made by hand is `"review": "pass"`, or `"fail"`
  with a `"note"`.

      GET /works/demo-1?kind=issue&root=/path/to/checkout

  Where the work is, as JSON, with nothing run. Either answer carries
  `"stopped"` (its step, reason and time) when the loop gave up on the work.
  """
  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  post "/work/run" do
    with %{"kind" => kind, "id" => "" <> _} = work <- conn.body_params,
         true <- checkout?(work),
         true <- kind in Workflow.Run.kinds() do
      answer(conn, work, Workflow.Run.start(work))
    else
      _other ->
        kinds = Enum.join(Workflow.Run.kinds(), ", ")

        reply(conn, 422, %{
          error: "a work has a kind (#{kinds}), an id and the root or repo of its checkout"
        })
    end
  end

  # A work names the checkout it runs in by its root, or by a repo to cut one beside.
  defp checkout?(%{"root" => "" <> _}), do: true
  defp checkout?(%{"repo" => "" <> _}), do: true
  defp checkout?(_not_named), do: false

  # Where a work is, with nothing run: GET /works/demo-1?kind=issue&root=/path/to/checkout
  get "/works/:id" do
    conn = fetch_query_params(conn)

    with %{"kind" => kind, "root" => "" <> _} = asked <- conn.query_params,
         true <- kind in Workflow.Run.kinds(),
         %{} = seen <- Workflow.Run.look(Map.put(asked, "id", id)) do
      reply(conn, 200, seen)
    else
      :none -> reply(conn, 422, %{error: "that root is not a git checkout"})
      _other -> reply(conn, 422, %{error: "name the work's kind and the root of its checkout"})
    end
  end

  # Says something to a work under way: {"id": ..., "root" or "repo": ..., "say": "..."}.
  # It is kept with the work and reaches its next agent turn, whichever agent,
  # as from the owner; it does not interrupt a turn already running.
  post "/work/say" do
    asked = conn.body_params
    # A repo's work is in the checkout cut beside it, if one was ever cut.
    root = asked["root"] || (asked["repo"] && Workflow.Checkout.root(asked["repo"], asked["id"]))

    with %{"id" => "" <> id, "say" => "" <> said} <- asked,
         true <- checkout?(asked),
         :ok <- Workflow.Checkout.say_to(root, id, said) do
      reply(conn, 200, %{said: said})
    else
      :none ->
        reply(conn, 404, %{error: "that work has no checkout"})

      _other ->
        reply(conn, 422, %{error: "name the work's id, its root or repo, and say something"})
    end
  end

  # The owner's go for a waiting prod provision, at the tree it is on now: the work as
  # handed in. Only from the service's own address, and only with the owner's word:
  # no chat or manager tool reaches it, and an agent's plain call is refused.
  post "/work/go" do
    # The word is taken off the work at once: nothing the loop writes ever carries it.
    {word, work} = Map.pop(conn.body_params, "word")
    root = work["root"] || (work["repo"] && Workflow.Checkout.root(work["repo"], work["id"]))

    with true <- conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] || :forbidden,
         true <- owners_word?(Application.get_env(:workflow, :go), word),
         %{"kind" => "provision", "id" => "" <> id} <- work,
         "" <> _ <- root do
      Workflow.Checkout.record(root, id, "go", %{"status" => "go"})
      answer(conn, work, Workflow.Run.start(work))
    else
      :forbidden ->
        reply(conn, 403, %{error: "only the service's own address gives the go"})

      :no_word_set ->
        reply(conn, 403, %{
          error:
            "no go word is set: put \"go\": the sha256 hex of the owner's word in " <>
              "#{Workflow.ConfigFile.path()} (printf %s 'word' | shasum -a 256) and restart"
        })

      :wrong_word ->
        reply(conn, 403, %{error: "the go needs the owner's word: {\"id\", \"word\"}"})

      _other ->
        reply(conn, 422, %{error: "name a provision's id and its root or repo"})
    end
  end

  # Whether `word` is the owner's: its sha256 against the hash held from config.json at
  # boot, compared in constant time. Neither is ever logged or written anywhere.
  #
  # Known limit: an agent with write access to config.json and the means to restart the
  # service could replace the hash. This stops a plain call, not that.
  defp owners_word?("" <> hash, "" <> word) do
    given = Base.encode16(:crypto.hash(:sha256, word), case: :lower)
    Plug.Crypto.secure_compare(given, String.downcase(hash)) || :wrong_word
  end

  defp owners_word?("" <> _hash, _no_word), do: :wrong_word
  defp owners_word?(_no_hash, _word), do: :no_word_set

  # Tells the project manager something, where there is one: {"say": "..."}.
  post "/manager" do
    case manager(conn.body_params) do
      {:ok, said} -> reply(conn, 200, %{said: said})
      {status, error} -> reply(conn, status, %{error: error})
    end
  end

  # What the manager said to {"say": "..."}, or the status and error of why not.
  defp manager(asked) do
    case {Workflow.Manager.configured(), asked} do
      {nil, _asked} -> {404, "no manager is configured"}
      {_manager, %{"say" => "" <> say}} -> {:ok, Workflow.Manager.tell(say)}
      {_manager, _asked} -> {422, "say something: {\"say\": \"...\"}"}
    end
  end

  # The manager over MCP's streamable HTTP, for chat sessions: JSON-RPC, by hand.
  post("/mcp", do: mcp(conn, [], "chat"))

  # The manager's own tools (hand_in, record, decide, look, tell, stop) as well, for one acting as
  # the manager, with the manager settings from config.json; 404 with none.
  post "/mcp/manager" do
    case Workflow.Manager.configured() do
      nil -> reply(conn, 404, %{error: "no manager is configured"})
      manager -> mcp(conn, Workflow.Manager.tools(manager))
    end
  end

  match _ do
    reply(conn, 404, %{
      error:
        "POST /work/run, GET /works/:id, POST /work/say, POST /work/go, POST /manager, POST /mcp, " <>
          "POST /mcp/manager"
    })
  end

  # One JSON-RPC request answered, with `tools` offered beside say and inbox; a tool's
  # answer ends with how many messages wait in `inbox`, where one is named.
  defp mcp(conn, tools, inbox \\ nil) do
    case conn.body_params do
      %{"id" => id, "method" => method} = asked ->
        reply(conn, 200, trailed(rpc(id, method, asked["params"], tools), asked, inbox))

      %{"method" => _notification} ->
        send_resp(conn, 202, "")

      _other ->
        reply(conn, 400, %{
          jsonrpc: "2.0",
          id: nil,
          error: %{code: -32600, message: "not a JSON-RPC request"}
        })
    end
  end

  # The one tool offered over MCP: the manager, and nothing else.
  @say %{
    name: "say",
    description:
      "Talk to the project manager. Before passing on something the person wants built or " <>
        "fixed, ask them questions, a few at a time, until you know who it is for, what they " <>
        "should be able to do, and two to four things the product does that would show it works. " <>
        "Then pass on the settled request in the person's own words, together with their answers. " <>
        "Never invent an answer: if you do not know, ask. A plain question about what is running, " <>
        "waiting, done or stopped goes straight through, with no questions first. " <>
        "Answers what the manager said. " <>
        "Optionally name who it is to (default the manager) and who it is from (default chat). " <>
        "To a claude-code or codex recipient it never waits: it answers at once that the " <>
        "message was delivered, and the reply will be in the inbox. " <>
        "When an answer ends with a line saying messages are in your inbox, read your inbox " <>
        "with the inbox tool. Put any message whose text begins \"Ask the user:\" to the person.",
    inputSchema: %{
      type: "object",
      properties: %{say: %{type: "string"}, to: %{type: "string"}, from: %{type: "string"}},
      required: ["say"]
    }
  }

  # The messages kept for a name since it last asked.
  @inbox %{
    name: "inbox",
    description:
      "Answers the messages kept for a name (default chat) since that name last asked, " <>
        "as JSON, each with its to, from and text, and marks them read: a second call does " <>
        "not return them again. Replies from claude-code and codex recipients arrive here.",
    inputSchema: %{
      type: "object",
      properties: %{name: %{type: "string"}}
    }
  }

  defp answer(conn, _work, {:none, _agent}),
    do: reply(conn, 422, %{error: "that root is not a git checkout"})

  defp answer(conn, work, {nil, _agent}),
    do: reply(conn, 200, %{done: true, log: Workflow.Run.log(work)})

  defp answer(conn, work, {step, agent}) do
    answered = %{
      done: false,
      step: step.name,
      actor: step.actor,
      note: step.note,
      agent: agent,
      log: Workflow.Run.log(work)
    }

    # A work the loop gave up on says why.
    case Workflow.Run.stopped(work) do
      nil -> reply(conn, 200, answered)
      stopped -> reply(conn, 200, Map.put(answered, :stopped, stopped))
    end
  end

  defp rpc(id, "initialize", params, _tools) do
    version = (is_map(params) && params["protocolVersion"]) || "2025-03-26"

    answered = %{
      protocolVersion: version,
      capabilities: %{tools: %{}},
      serverInfo: %{name: "workflow", version: "0.1.0"}
    }

    # The chat's brief, where config.json names one (`Workflow.ConfigFile`).
    case Application.get_env(:workflow, :instructions) do
      nil -> result(id, answered)
      brief -> result(id, Map.put(answered, :instructions, brief))
    end
  end

  defp rpc(id, "tools/list", _params, tools) do
    listed =
      for tool <- tools,
          do: %{name: tool.name, description: tool.description, inputSchema: tool.input_schema}

    result(id, %{tools: listed ++ [@say, @inbox]})
  end

  # Kept in the recipient's inbox, then delivered: to the manager by default, from chat.
  defp rpc(id, "tools/call", %{"name" => "say"} = params, _tools) do
    case params["arguments"] do
      %{"say" => "" <> text} = asked ->
        told(id, Workflow.Messages.say(asked["to"] || "manager", asked["from"] || "chat", text))

      _other ->
        told(id, {:error, "say something: {\"say\": \"...\"}"})
    end
  end

  # The messages kept for a name (chat by default) since it last asked, now read.
  defp rpc(id, "tools/call", %{"name" => "inbox"} = params, _tools) do
    name = (is_map(params["arguments"]) && params["arguments"]["name"]) || "chat"
    told(id, {:ok, Jason.encode!(Workflow.Messages.unread(name))})
  end

  # One of the manager's own tools, run as the service-run manager runs it.
  defp rpc(id, "tools/call", %{"name" => name} = params, tools) do
    case Enum.find(tools, &(&1.name == name)) do
      nil ->
        %{jsonrpc: "2.0", id: id, error: %{code: -32602, message: "unknown tool #{name}"}}

      tool ->
        arguments = if is_map(params["arguments"]), do: params["arguments"], else: %{}
        told(id, executed(tool, arguments))
    end
  end

  defp rpc(id, method, _params, _tools),
    do: %{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "no method #{method}"}}

  # A tool's answer; arguments it cannot take are an error result, not a crash.
  defp executed(tool, arguments) do
    case tool.execute.(arguments, %{}) do
      {:ok, said, _structured} -> {:ok, said}
      {:error, error} -> {:error, to_string(error)}
      said -> said
    end
  rescue
    FunctionClauseError -> {:error, "#{tool.name}: #{Jason.encode!(tool.input_schema)}"}
  end

  defp told(id, {:ok, said}), do: result(id, %{content: [%{type: "text", text: said}]})

  defp told(id, {:error, error}),
    do: result(id, %{content: [%{type: "text", text: error}], isError: true})

  defp result(id, result), do: %{jsonrpc: "2.0", id: id, result: result}

  # A tool's answer, other than the inbox's own, ends with the unread messages waiting.
  defp trailed(
         %{result: %{content: [%{text: said} = content]} = result} = answered,
         %{"method" => "tools/call", "params" => %{"name" => name}},
         "" <> inbox
       )
       when name != "inbox" do
    case Workflow.Messages.waiting(inbox) do
      0 ->
        answered

      count ->
        line = "#{count} #{if count == 1, do: "message is", else: "messages are"} in your inbox."
        %{answered | result: %{result | content: [%{content | text: said <> "\n\n" <> line}]}}
    end
  end

  defp trailed(answered, _asked, _inbox), do: answered

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
