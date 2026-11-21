defmodule Workflow.Server do
  @moduledoc """
  The loop's line to the server: it dials out (a server cannot reach into a
  developer's machine), joins the channel `loop:<project_id>`, and relays text
  between the server's chat agent and the manager. The server pushes `"say"`
  (`ref`, `text`); the manager is told the text exactly as `POST /manager` tells
  it (`Workflow.Manager.tell/1`) and `"said"` (the same `ref`, the reply `text`)
  goes back. The loop also pushes `"report"`, a work's whole picture
  (`Workflow.Report`), and reads nothing back for it. Nothing else crosses: the
  manager is spoken to, never driven.

  Started only when `config.json` has a `"server"` object:
  `{"url": "wss://host/socket/websocket", "project_id": "..."}`, and optionally
  `"state_dir"` (default `$CMS_STATE_DIR`, else `~/.codemyspec`). The credential
  is the one the harness already holds for that server (its device sign-in,
  `harness_oauth_<sha256 of the server's base URL>.json` in the state dir): read,
  never written, and re-read at every reconnect. Sign in with the harness first.
  """
  use Slipstream

  require Logger

  @doc "The `{event, payload}` pushed back for a `\"say\"`, running the manager as the route does."
  @spec answer(map(), (String.t() -> String.t() | nil)) :: {String.t(), map()}
  def answer(%{"ref" => ref, "text" => text}, tell \\ &Workflow.Manager.tell/1) do
    reply =
      try do
        if Workflow.Manager.configured(),
          do: tell.(text) || "",
          else: "The loop has no manager configured, so nothing was said to it."
      catch
        kind, why -> "The manager failed (#{kind}): #{Exception.format_banner(kind, why)}"
      end

    {"said", %{"ref" => ref, "text" => reply}}
  end

  # Named, so `Workflow.Report` finds the line to send a report on.
  def start_link(%{} = server), do: Slipstream.start_link(__MODULE__, server, name: __MODULE__)

  @impl Slipstream
  def init(server) do
    socket =
      new_socket() |> assign(:server, server) |> assign(:topic, "loop:#{server["project_id"]}")

    {:ok, connect!(socket, uri: uri(server))}
  end

  @impl Slipstream
  def handle_connect(socket), do: {:ok, join(socket, socket.assigns.topic)}

  @impl Slipstream
  def handle_message(_topic, "say", %{"ref" => _, "text" => "" <> _} = say, socket) do
    me = self()
    Logger.info("[Workflow.Server] say #{say["ref"]}")
    Task.start(fn -> send(me, {:said, answer(say)}) end)
    {:ok, socket}
  end

  def handle_message(_topic, _event, _payload, socket), do: {:ok, socket}

  @impl Slipstream
  def handle_info({:said, {event, payload}}, socket) do
    Logger.info("[Workflow.Server] said #{payload["ref"]}")
    push(socket, socket.assigns.topic, event, payload)
    {:noreply, socket}
  end

  # A work's whole picture (`Workflow.Report`). A send that fails is logged and
  # dropped: nothing is queued or retried, and the next report says it all again.
  def handle_info({:report, report}, socket) do
    with {:error, why} <- push(socket, socket.assigns.topic, "report", report) do
      Logger.warning("[Workflow.Server] report on #{report["work"]} not sent: #{inspect(why)}")
    end

    {:noreply, socket}
  end

  # A refused or dropped join is tried again, at Slipstream's own pace.
  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Logger.warning("[Workflow.Server] #{topic} closed: #{inspect(reason)}")
    rejoin(socket, topic)
  end

  @impl Slipstream
  def handle_join(topic, _reply, socket) do
    Logger.info("[Workflow.Server] joined #{topic}")
    # Each join, first or again, reports every work in flight; the first also
    # every journey file with no work, as not started.
    started = if socket.assigns[:started], do: [], else: Workflow.Report.unstarted(repo())
    for report <- Workflow.Report.in_flight() ++ started, do: send(self(), {:report, report})
    {:ok, assign(socket, :started, true)}
  end

  # The repository works are cut from, the manager's.
  defp repo do
    case Application.get_env(:workflow, :manager) do
      %{"repo" => "" <> repo} -> repo
      _none -> nil
    end
  end

  # Each retry dials with the credential as it is now: the harness refreshes it.
  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    config = %{socket.channel_config | uri: URI.parse(uri(socket.assigns.server))}
    reconnect(%{socket | channel_config: config})
  end

  defp uri(%{"url" => url} = server) do
    case token(server) do
      nil ->
        Logger.warning(
          "[Workflow.Server] no unexpired sign-in for #{base(url)}; sign the harness in"
        )

        url

      token ->
        url <>
          if(String.contains?(url, "?"), do: "&", else: "?") <> URI.encode_query(token: token)
    end
  end

  # The harness's file for this server (its `HarnessOAuth`), read in place.
  defp token(%{"url" => url} = server) do
    dir = server["state_dir"] || System.get_env("CMS_STATE_DIR") || "~/.codemyspec"
    hash = :crypto.hash(:sha256, base(url)) |> Base.encode16(case: :lower)

    with {:ok, body} <- File.read(Path.expand(Path.join(dir, "harness_oauth_#{hash}.json"))),
         {:ok, %{"access_token" => "" <> token, "expires_at" => expires}} <- Jason.decode(body),
         true <- is_integer(expires) and expires > System.system_time(:second) + 30 do
      token
    else
      _none -> nil
    end
  end

  # The server's base URL as the harness names it: http(s), no path.
  defp base(url) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "wss", do: "https", else: "http"
    to_string(%URI{scheme: scheme, host: uri.host, port: uri.port})
  end
end
