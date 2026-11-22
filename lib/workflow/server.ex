defmodule Workflow.Server do
  @moduledoc """
  The loop's line to the server: it dials out (a server cannot reach into a
  developer's machine), joins the channel `loop:<project_id>`, and relays text
  between the server's chat agent and the manager. The server pushes `"say"`
  (`ref`, `text`); the manager is told the text exactly as `POST /manager` tells
  it (`Workflow.Manager.tell/1`) and `"said"` (the same `ref`, the reply `text`)
  goes back. The loop also pushes `"report"`, a work's whole picture
  (`Workflow.Report`), and reads nothing back for it.

  The server pushes `"event"` (`work`, `name`, `payload`): it is recorded for
  that work (`Workflow.Run.event/3`), as `POST /works/:id/events` records one.
  The loop pushes `"presign"` and `"uploaded"` for evidence (`Workflow.Upload`)
  and `"pushed"` (`branch`, `commit`) once it has pushed the main copy, and
  `"message"` (`text`) for the person's chat inbox, answered ok `id`
  (the manager's `message_chat`).

  Started only when `config.json` has a `"server"` object:
  `{"url": "wss://host/socket/websocket", "project_id": "..."}`, and optionally
  `"state_dir"` (default `$CMS_STATE_DIR`, else `~/.codemyspec`). The credential
  is the loop's own device sign-in (`workflow sign-in`, see `Workflow.SignIn`),
  re-read at every reconnect and refreshed before dialing when about to expire.
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

  @doc """
  Pushes `event` and waits for the server's reply: `{:ok, payload}`, or
  `{:error, why}` with no line, no reply in `timeout`, or a refusal.
  """
  @spec call(String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def call(event, payload, timeout \\ 15_000) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :no_server}
      pid -> GenServer.call(pid, {:push, event, payload}, timeout)
    end
  catch
    :exit, why -> {:error, {:no_reply, why}}
  end

  @doc "Pushes `event` with nothing waited for; nothing with no line."
  @spec push(String.t(), map()) :: :ok
  def push(event, payload) do
    with pid when is_pid(pid) <- GenServer.whereis(__MODULE__),
         do: send(pid, {:push, event, payload})

    :ok
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

  def handle_message(_topic, "event", %{"work" => "" <> id, "name" => "" <> name} = event, socket) do
    Logger.info("[Workflow.Server] event #{name} for #{id}")
    Task.start(fn -> Workflow.Run.event(id, name, event["payload"]) end)
    {:ok, socket}
  end

  def handle_message(_topic, _event, _payload, socket), do: {:ok, socket}

  # A push whose reply is waited on: the caller is answered when it comes.
  @impl Slipstream
  def handle_call({:push, event, payload}, from, socket) do
    case push(socket, socket.assigns.topic, event, payload) do
      {:ok, ref} ->
        calls = Map.put(socket.assigns[:calls] || %{}, ref, from)
        {:noreply, assign(socket, calls: calls, last_push: event)}

      {:error, why} ->
        {:reply, {:error, why}, socket}
    end
  end

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    case Map.pop(socket.assigns[:calls] || %{}, ref) do
      {nil, _calls} ->
        {:ok, socket}

      {from, calls} ->
        GenServer.reply(from, reply)
        {:ok, assign(socket, :calls, calls)}
    end
  end

  @impl Slipstream
  def handle_info({:said, {event, payload}}, socket) do
    Logger.info("[Workflow.Server] said #{payload["ref"]}")
    push(socket, socket.assigns.topic, event, payload)
    {:noreply, assign(socket, :last_push, event)}
  end

  def handle_info({:push, event, payload}, socket) do
    case push(socket, socket.assigns.topic, event, payload) do
      {:ok, _ref} ->
        {:noreply, assign(socket, :last_push, event)}

      {:error, why} ->
        Logger.warning("[Workflow.Server] #{event} not sent: #{inspect(why)}")
        {:noreply, socket}
    end
  end

  # A work's whole picture (`Workflow.Report`). A send that fails is logged and
  # dropped: nothing is queued or retried, and the next report says it all again.
  # A server that does not take reports (see `handle_topic_close/3`) is sent none.
  def handle_info({:report, _report}, %{assigns: %{no_reports: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:report, report}, socket) do
    case push(socket, socket.assigns.topic, "report", report) do
      {:ok, _ref} ->
        {:noreply, assign(socket, :last_push, "report")}

      {:error, why} ->
        Logger.warning("[Workflow.Server] report on #{report["work"]} not sent: #{inspect(why)}")
        {:noreply, socket}
    end
  end

  # A refused or dropped join is tried again after Slipstream's `rejoin_after_msec`
  # pause. Slipstream sets its rejoin count back to 0 on every join that succeeds,
  # so a channel that is joined and then closes would be rejoined at its first
  # pause every time: the count of closes is kept here and given back to it, so
  # the pause grows on each close up to the list's last (its cap).
  #
  # A channel that crashes straight after a report is taken as a server that does
  # not take reports (an older app): no more are pushed for the life of the process.
  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Logger.warning("[Workflow.Server] #{topic} closed: #{inspect(reason)}")
    closes = Map.get(socket.assigns, :closes, 0)

    socket =
      socket
      |> no_reports(reason)
      |> assign(closes: closes + 1, last_push: nil)

    socket =
      if Map.has_key?(socket.joins, topic),
        do: put_in(socket.joins[topic].rejoin_counter, closes),
        else: socket

    rejoin(socket, topic)
  end

  defp no_reports(%{assigns: %{last_push: "report"} = assigns} = socket, reason)
       when not is_map_key(assigns, :no_reports) do
    case reason do
      {:error, %{"reason" => "channel_crash"}} ->
        Logger.warning(
          "[Workflow.Server] the channel crashed on a report: this server does not take reports, so no more are sent"
        )

        assign(socket, :no_reports, true)

      _other ->
        socket
    end
  end

  defp no_reports(socket, _reason), do: socket

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

  # Each retry dials with the credential as it is now, refreshed if expiring.
  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    config = %{socket.channel_config | uri: URI.parse(uri(socket.assigns.server))}
    reconnect(%{socket | channel_config: config})
  end

  @doc "The URL to dial: the server's, with a token from `Workflow.SignIn.token/2` (refreshed if expiring)."
  @spec uri(map(), Workflow.SignIn.http()) :: String.t()
  def uri(%{"url" => url} = server, http \\ &Workflow.SignIn.post/2) do
    case Workflow.SignIn.token(server, http) do
      nil ->
        Logger.warning(
          "[Workflow.Server] no sign-in for #{Workflow.SignIn.base(url)}; run `workflow sign-in`"
        )

        url

      token ->
        url <>
          if(String.contains?(url, "?"), do: "&", else: "?") <> URI.encode_query(token: token)
    end
  end
end
