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
  and `"pushed"` (`branch`, `commit`, the landing `work`) once it has pushed the main copy, and
  `"message"` (`text`) for the person's chat inbox, answered ok `id`
  (the manager's `message_chat`).

  A work is a server record (`Workflow.Works`, `notes/works_contract.md`): the
  loop calls `"hand_in"` and `"claim"`, the server pushes `"work"` for a record
  it made, and at its first join the loop calls `"claimed"` to run its works on.

  The join carries `harness_id` when `CMS_HARNESS_ID` is set. On Code My Spec's
  own loop the server pushes `"start_support"` (`project_id`, `thread_id`,
  `question`, `resume`): a support session answers it and the loop pushes
  `"support_session"` (`thread_id`, `resume`). Support's answer comes to the
  asking loop as `"wake"` (`text`), told the manager as a say is.

  A server whose join reply carries `"resume" => true` gives an answered parked
  work its slot: the work waits until the server pushes `"resume"` (`work`, its
  record) for it (`resumes?/0`, `Workflow.Run.server_resumed/1`).

  Started only when `config.json` has a `"server"` object:
  `{"url": "wss://host/socket/websocket", "project_id": "..."}`, and optionally
  `"state_dir"` (default `$CMS_STATE_DIR`, else `~/.codemyspec`). Each entry of
  `"servers"`, a list of the same objects, gets a line of its own that is sent
  every report and `"pushed"` (`lines/0`, `push_all/2`) and answers its own
  says and events; calls, uploads and the chat inbox stay on `"server"`'s. The credential
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

  @doc "Pushes `event` on every line (`lines/0`), nothing waited for."
  @spec push_all(String.t(), map()) :: :ok
  def push_all(event, payload) do
    for pid <- lines(), do: send(pid, {:push, event, payload})
    :ok
  end

  @doc "Every line that is up: `\"server\"`'s, then one per `\"servers\"` entry."
  @spec lines() :: [pid()]
  def lines do
    extra = Application.get_env(:workflow, :servers) || []
    names = [__MODULE__ | Enum.map(1..length(extra)//1, &name/1)]
    for name <- names, pid = Process.whereis(name), do: pid
  end

  @doc "The name of the `n`th extra line."
  def name(n), do: Module.concat(__MODULE__, "Line#{n}")

  @doc """
  Whether `"server"`'s server, at its last join, said it gives an answered
  parked work its slot (its join reply's `"resume"`): such a work then waits
  for the `"resume"` push. False with no line yet, or from an older server.
  """
  @spec resumes?() :: boolean()
  def resumes?, do: Application.get_env(:workflow, :resumes) == true

  # Named, so `Workflow.Report` finds the lines to send a report on.
  def start_link(%{} = server), do: start_link({server, __MODULE__})
  def start_link({%{} = server, name}), do: Slipstream.start_link(__MODULE__, server, name: name)

  @impl Slipstream
  def init(server) do
    socket =
      new_socket() |> assign(:server, server) |> assign(:topic, "loop:#{server["project_id"]}")

    {:ok, connect!(socket, dial(server))}
  end

  @impl Slipstream
  def handle_connect(socket), do: {:ok, join(socket, socket.assigns.topic, harness())}

  # The harness this loop runs on, as `CMS_HARNESS_ID` names it: none when unset.
  defp harness do
    case System.get_env("CMS_HARNESS_ID") do
      "" <> id when id != "" -> %{"harness_id" => id}
      _none -> %{}
    end
  end

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

  # A work the server made at hand-in: claimed, then run (`Workflow.Works`).
  def handle_message(_topic, "work", %{"id" => "" <> id, "kind" => "" <> _} = record, socket) do
    Logger.info("[Workflow.Server] work #{id}")
    Task.start(fn -> Workflow.Works.taken(record) end)
    {:ok, socket}
  end

  # A manager's question to support (on Code My Spec's own loop): a support
  # session answers it (`Workflow.Agents.support/1`), and once it has a resume
  # handle the server is told it. Not a work: no copy, works file or slot.
  def handle_message(_topic, "start_support", %{"thread_id" => "" <> thread} = ask, socket) do
    me = self()
    Logger.info("[Workflow.Server] start_support #{thread}")

    Task.start(fn ->
      with "" <> resume <- Workflow.Agents.support(ask),
           do: send(me, {:support_session, %{"thread_id" => thread, "resume" => resume}})
    end)

    {:ok, socket}
  end

  # Support's answer, told the manager as a say is.
  def handle_message(_topic, "wake", %{"text" => "" <> text} = wake, socket) do
    Logger.info("[Workflow.Server] wake from #{wake["from"]} on #{wake["thread_id"]}")
    Task.start(fn -> answer(%{"ref" => wake["thread_id"], "text" => text}) end)
    {:ok, socket}
  end

  # The server gave a slot to a parked work answered while every slot was taken.
  def handle_message(_topic, "resume", %{"work" => %{"id" => "" <> id}}, socket) do
    Logger.info("[Workflow.Server] resume #{id}")
    Task.start(fn -> Workflow.Run.server_resumed(id) end)
    {:ok, socket}
  end

  # Someone on the project reordered its queue: taken as given from the next free slot.
  def handle_message(_topic, "reorder", %{"order" => ids}, socket) when is_list(ids) do
    Logger.info("[Workflow.Server] reorder #{Enum.join(ids, ", ")}")
    Task.start(fn -> Workflow.Run.reorder(ids) end)
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

      {{:support_session, thread}, calls} ->
        with {:error, why} <- reply,
             do:
               Logger.warning(
                 "[Workflow.Server] support_session #{thread} refused: #{inspect(why)}"
               )

        {:ok, assign(socket, :calls, calls)}

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

  # Its reply is only logged when an error (`handle_reply/3`); the session goes on.
  def handle_info({:support_session, %{"thread_id" => thread} = session}, socket) do
    case push(socket, socket.assigns.topic, "support_session", session) do
      {:ok, ref} ->
        calls = Map.put(socket.assigns[:calls] || %{}, ref, {:support_session, thread})
        {:noreply, assign(socket, calls: calls, last_push: "support_session")}

      {:error, why} ->
        Logger.warning("[Workflow.Server] support_session #{thread} not sent: #{inspect(why)}")
        {:noreply, socket}
    end
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
  # kept, the newest a work, in the order the works last changed, and sent at
  # the next join (`handle_join/3`). Seen live: a picture dropped while the line
  # was down left the server showing a work at a step it had left.
  # A server that does not take reports (see `handle_topic_close/3`) is sent none.
  def handle_info({:report, _report}, %{assigns: %{no_reports: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:report, report}, socket) do
    # Each line's server knows the project by its own id.
    report =
      case socket.assigns[:server] do
        %{"project_id" => "" <> id} when is_map_key(report, "project") ->
          %{report | "project" => id}

        _none ->
          report
      end

    case push(socket, socket.assigns.topic, "report", report) do
      {:ok, _ref} ->
        {:noreply, assign(socket, :last_push, "report")}

      {:error, why} ->
        Logger.warning("[Workflow.Server] report on #{report["work"]} not sent: #{inspect(why)}")
        {:noreply, kept(socket, report)}
    end
  end

  defp kept(socket, %{"status" => _, "work" => work} = report) do
    kept = Enum.reject(socket.assigns[:kept] || [], &(&1["work"] == work))
    assign(socket, :kept, kept ++ [report])
  end

  defp kept(socket, _report), do: socket

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
  def handle_join(topic, reply, socket) do
    Logger.info("[Workflow.Server] joined #{topic}")

    # `"server"`'s line: whether its server gives an answered parked work its
    # slot by `"resume"`. Absent, as from an older server, the loop does.
    if Process.whereis(__MODULE__) == self(),
      do: Application.put_env(:workflow, :resumes, is_map(reply) and reply["resume"] == true)

    # Each join, first or again, sends once each report kept while the line was
    # down, then reports every work in flight as it is now, so a work's newest
    # picture is its last; the first join also every journey file with no work,
    # as not started.
    started = if socket.assigns[:started], do: [], else: Workflow.Report.unstarted(repo())
    kept = socket.assigns[:kept] || []

    for report <- kept ++ Workflow.Report.in_flight() ++ started,
        do: send(self(), {:report, report})

    # The first join of `"server"`'s line after the loop starts: the works it has
    # claimed are read back from their records and run on (`Workflow.Works.recover/0`).
    if !socket.assigns[:started] and Process.whereis(__MODULE__) == self(),
      do: Task.start(&Workflow.Works.recover/0)

    {:ok, assign(socket, started: true, kept: [])}
  end

  # The repository works are cut from, the manager's.
  defp repo do
    case Application.get_env(:workflow, :manager) do
      %{"repo" => "" <> repo} -> repo
      _none -> nil
    end
  end

  # Each retry dials with the credential as it is now, refreshed if expiring, in
  # the `x-cms-token` header. A header connect refused with 403 (a server not yet
  # taking the header) is tried once with the token in the query form; no other
  # failure is, and the next retry after that is the header again.
  @impl Slipstream
  def handle_disconnect(reason, socket) do
    form = if refused?(reason) and socket.assigns[:form] != :query, do: :query, else: :header
    dial = dial(socket.assigns.server, form)
    config = %{socket.channel_config | uri: URI.parse(dial[:uri]), headers: dial[:headers]}
    reconnect(%{assign(socket, :form, form) | channel_config: config})
  end

  defp refused?({:error, {:upgrade_failure, %{status_code: 403}}}), do: true
  defp refused?(_reason), do: false

  @doc """
  What to dial: the server's url, and a token from `Workflow.SignIn.token/2`
  (refreshed if expiring) in the `x-cms-token` header, or with `form` `:query`
  in the url's query string instead (for a server not yet taking the header).
  """
  @spec dial(map(), :header | :query, Workflow.SignIn.http()) :: keyword()
  def dial(%{"url" => url} = server, form \\ :header, http \\ &Workflow.SignIn.post/2) do
    case {Workflow.SignIn.token(server, http), form} do
      {nil, _form} ->
        Logger.warning(
          "[Workflow.Server] no sign-in for #{Workflow.SignIn.base(url)}; run `workflow sign-in`"
        )

        [uri: url, headers: []]

      {token, :header} ->
        [uri: url, headers: [{"x-cms-token", token}]]

      {token, :query} ->
        query =
          if(String.contains?(url, "?"), do: "&", else: "?") <> URI.encode_query(token: token)

        [uri: url <> query, headers: []]
    end
  end
end
