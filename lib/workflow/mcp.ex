defmodule Workflow.Mcp do
  @moduledoc """
  The plugin's MCP servers as an agent's tools. Claude Code is only the model
  here and Alloy runs the tools, so the loop is the MCP client: each server the
  plugin's `.mcp.json` names (a `command` spoken to over stdio, or a `url` over
  HTTP) is asked for its tools, and each is handed to the agent as
  `mcp__<server>__<tool>`, as Claude Code names them. Calling one asks the
  server. A server that gives no tools is logged and left out; it never ends
  the turn.
  """

  require Logger

  @timeout 120_000

  @doc "The tools of every MCP server in the plugin's `.mcp.json`; none without one."
  @spec tools() :: [Alloy.Tool.Inline.t()]
  def tools do
    with "" <> path <- Workflow.Plugin.mcp(),
         {:ok, text} <- File.read(path),
         text = String.replace(text, "${CLAUDE_PLUGIN_ROOT}", Workflow.Plugin.dir()),
         {:ok, %{"mcpServers" => %{} = servers}} <- Jason.decode(text) do
      Enum.flat_map(servers, fn {name, server} -> tools(name, server) end)
    else
      _none -> []
    end
  end

  defp tools(name, server) do
    case session(server, %{method: "tools/list", params: %{}}) do
      {:ok, %{"result" => %{"tools" => tools}}} ->
        Enum.map(tools, &tool(name, server, &1))

      other ->
        Logger.warning("[Workflow] the MCP server #{name} gave no tools: #{inspect(other)}")
        []
    end
  end

  defp tool(name, server, %{"name" => tool} = listed) do
    Alloy.Tool.inline(
      name: "mcp__#{name}__#{tool}",
      description: listed["description"] || tool,
      input_schema: listed["inputSchema"] || %{"type" => "object"},
      execute: fn input, _context -> call(server, tool, input) end
    )
  end

  defp call(server, tool, input) do
    case session(server, %{method: "tools/call", params: %{name: tool, arguments: input}}) do
      {:ok, %{"result" => result}} ->
        text = Enum.map_join(result["content"] || [], "\n", &(&1["text"] || inspect(&1)))
        if result["isError"], do: {:error, text}, else: {:ok, text}

      {:ok, %{"error" => error}} ->
        {:error, error["message"] || inspect(error)}

      {:error, why} ->
        {:error, "the MCP server failed: #{inspect(why)}"}
    end
  end

  @initialize %{
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: %{
      protocolVersion: "2025-03-26",
      capabilities: %{},
      clientInfo: %{name: "workflow", version: "1"}
    }
  }
  @initialized %{jsonrpc: "2.0", method: "notifications/initialized"}

  # One request in its own session: initialize, then the request, its answer.
  defp session(%{"url" => url} = server, request) do
    headers =
      Map.merge(%{"accept" => "application/json, text/event-stream"}, server["headers"] || %{})

    with {:ok, %{"result" => _}, id} <- post(url, headers, @initialize),
         headers = if(id, do: Map.put(headers, "mcp-session-id", id), else: headers),
         {:ok, _, _} <- post(url, headers, @initialized),
         {:ok, answer, _} <- post(url, headers, Map.merge(request, %{jsonrpc: "2.0", id: 2})) do
      {:ok, answer}
    end
  end

  defp session(%{"command" => command} = server, request) do
    env = for {key, value} <- server["env"] || %{}, do: {~c"#{key}", ~c"#{value}"}
    options = [:binary, :exit_status, {:line, 1_000_000}, args: server["args"] || [], env: env]
    port = Port.open({:spawn_executable, System.find_executable(command) || command}, options)

    try do
      line(port, @initialize)

      with {:ok, _} <- answer(port, 1, "") do
        line(port, @initialized)
        line(port, Map.merge(request, %{jsonrpc: "2.0", id: 2}))
        answer(port, 2, "")
      end
    after
      if Port.info(port), do: Port.close(port)
      flush(port)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp session(_server, _request), do: {:error, "names neither a command nor a url"}

  defp post(url, headers, body) do
    case Req.post(url,
           json: body,
           headers: headers,
           retry: false,
           decode_body: false,
           receive_timeout: @timeout
         ) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, decode(response.body),
         List.first(Req.Response.get_header(response, "mcp-session-id"))}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, error} ->
        {:error, error}
    end
  end

  # A JSON answer, or the last JSON-RPC answer of an event stream.
  defp decode(body) do
    case Jason.decode(body) do
      {:ok, answer} ->
        answer

      _stream ->
        for(
          "data:" <> data <- String.split(body, ["\r\n", "\n"]),
          {:ok, %{} = answer} <- [Jason.decode(data)],
          do: answer
        )
        |> List.last()
    end
  end

  defp line(port, message), do: Port.command(port, [Jason.encode!(message), "\n"])

  # The answer with `id`, passing over anything else the server prints.
  defp answer(port, id, part) do
    receive do
      {^port, {:data, {:noeol, more}}} ->
        answer(port, id, part <> more)

      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(part <> line) do
          {:ok, %{"id" => ^id} = answer} -> {:ok, answer}
          _other -> answer(port, id, "")
        end

      {^port, {:exit_status, status}} ->
        {:error, "exited with #{status}"}
    after
      @timeout -> {:error, :timeout}
    end
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
