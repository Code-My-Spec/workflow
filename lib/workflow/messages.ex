defmodule Workflow.Messages do
  @moduledoc """
  Messages between named recipients: kept first, then delivered.

  A message is to, from and text. Keeping it appends it, as one JSON line, to
  the recipient's inbox: `inbox/<to>.jsonl` beside the works directory.

  Delivery depends only on the recipient's kind, named under `:recipients` in
  the configuration, `%{"name" => %{"kind" => kind, ...}}`:

    * `"service"`, one the service runs itself (the project manager, which is
      also what `"manager"` is when no recipient of that name is configured
      and the manager has an `"agent"`): it gets the message as its next turn
      and its answer comes back. A manager with no `"agent"` and no recipient
      of that name is an inbox, as `"chat"` is.
    * `"claude-code"`, with a `"socket"`: the message is dropped into the
      session socket as one user message.
    * `"codex"`, with a `"thread"`: the message is queued with
      `codex queue --thread <thread> --message <text>`.
    * `"chat"`, or a name not configured: nothing is pushed; it sits in the inbox.

  What a service-run recipient answers to a message from `"workflow"` (the
  loop) is logged as one warning naming the work and kept in the chat's inbox,
  where the owner's chat reads it.

  A failed delivery leaves the message in the inbox and is reported in the
  answer; it is never raised.

  The socket connect (`:connect`) and the command (`:cmd`) are the
  application's to replace, so tests touch no real socket and no real codex.
  """

  require Logger

  @connect_timeout_ms 2_000

  @doc """
  Keeps `text` from `from` in `to`'s inbox, then delivers it. `{:ok, answer}`,
  or `{:error, why}` when delivery failed (the message is still kept).
  """
  @spec say(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def say(to, from, text) do
    keep(%{to: to, from: from, text: text})
    recipient = recipient(to)

    try do
      recipient |> deliver_to(to, text) |> answered(recipient, to, from, text)
    rescue
      error -> {:error, "Kept in #{to}'s inbox, but delivery failed: #{Exception.message(error)}"}
    catch
      kind, reason ->
        {:error, "Kept in #{to}'s inbox, but delivery failed: #{inspect({kind, reason})}"}
    end
  end

  @doc "The messages kept for `name` since it last asked; they are marked read."
  @spec unread(String.t()) :: [map()]
  def unread(name) do
    path = inbox(name)

    case File.read(path) do
      {:ok, body} ->
        lines = unread_lines(path, body)
        File.write!(path <> ".read", Integer.to_string(byte_size(body)))
        Enum.map(lines, &Jason.decode!/1)

      {:error, _none} ->
        []
    end
  end

  @doc "How many messages are kept for `name` since it last asked; none are marked read."
  @spec waiting(String.t()) :: non_neg_integer()
  def waiting(name) do
    path = inbox(name)

    case File.read(path) do
      {:ok, body} -> length(unread_lines(path, body))
      {:error, _none} -> 0
    end
  end

  # The lines of `body`, the inbox at `path`, past its read mark.
  defp unread_lines(path, body) do
    from =
      case File.read(path <> ".read") do
        {:ok, at} -> min(String.to_integer(String.trim(at)), byte_size(body))
        {:error, _none} -> 0
      end

    body
    |> binary_part(from, byte_size(body) - from)
    |> String.split("\n", trim: true)
  end

  @doc "Where `name`'s messages are kept."
  @spec inbox(String.t()) :: String.t()
  def inbox(name),
    do: Path.join([Path.dirname(Workflow.Run.works_dir()), "inbox", "#{name}.jsonl"])

  defp keep(%{to: to} = message) do
    path = inbox(to)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(message) <> "\n", [:append])
  end

  # A service-run recipient's answer to the loop has nobody on the other end of
  # the call: it is logged, naming the work, and kept for the owner's chat.
  defp answered({:ok, "" <> answer} = said, %{"kind" => "service"}, to, "workflow", text)
       when answer != "" do
    work = text |> String.split(":", parts: 2) |> hd()
    Logger.warning("#{work}: #{to} answered the loop: #{answer}")
    keep(%{to: "chat", from: to, text: answer})
    said
  end

  defp answered(said, _recipient, _to, _from, _text), do: said

  defp recipient(name) do
    case Application.get_env(:workflow, :recipients, %{}) do
      %{^name => %{} = recipient} -> recipient
      _none when name == "manager" -> manager_recipient(Workflow.Manager.configured())
      _none -> %{"kind" => "chat"}
    end
  end

  # The service runs the manager's turns only where it has an agent to run on;
  # a manager with none is an inbox, its messages read by whoever acts for it.
  defp manager_recipient(%{"agent" => %{}}), do: %{"kind" => "service"}
  defp manager_recipient(%{}), do: %{"kind" => "chat"}
  defp manager_recipient(_none), do: %{"kind" => "service"}

  defp deliver_to(%{"kind" => "service"}, _to, text) do
    case Workflow.Manager.configured() do
      nil -> {:error, "no manager is configured"}
      _manager -> {:ok, Workflow.Manager.tell(text)}
    end
  end

  defp deliver_to(%{"kind" => "claude-code", "socket" => socket}, to, text),
    do: delivered(to, deliver(socket, text))

  defp deliver_to(%{"kind" => "codex", "thread" => thread}, to, text),
    do: delivered(to, queue_into(thread, text))

  defp deliver_to(%{"kind" => "chat"}, to, _text),
    do: {:ok, "Kept in #{to}'s inbox; nothing is pushed to #{to}."}

  defp deliver_to(recipient, to, _text),
    do:
      {:error,
       "Kept in #{to}'s inbox, but #{inspect(recipient)} is not a recipient to deliver to."}

  defp delivered(to, :ok),
    do: {:ok, "Delivered to #{to}. It does not answer here: the reply will be in the inbox."}

  defp delivered(to, {:error, reason}),
    do: {:error, "Kept in #{to}'s inbox, but delivery failed: #{inspect(reason)}"}

  # Ported from CmsHarness.Agents.Terminal.queue_into/2.
  defp queue_into(thread, text) do
    codex = Application.get_env(:workflow, :codex_command, "codex")

    case cmd(codex, ["queue", "--thread", thread, "--message", text]) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:codex_queue, status, String.trim(out)}}
    end
  end

  defp cmd(command, args),
    do:
      Application.get_env(:workflow, :cmd, &System.cmd/3).(command, args, stderr_to_stdout: true)

  # Ported from CmsHarness.Agents.Terminal.deliver/2: `text` as one user message.
  defp deliver(socket, text) do
    frames = auth_frame(socket) ++ [frame(text)]

    with {:ok, conn} <- connect(socket) do
      result = :gen_tcp.send(conn, frames)
      :gen_tcp.close(conn)
      result
    end
  end

  defp frame(text),
    do: Jason.encode!(%{type: "user", message: %{role: "user", content: text}}) <> "\n"

  # Sent whenever the session published a key, as peers of the same user do.
  defp auth_frame(socket) do
    case peer_token(socket) do
      nil -> []
      token -> [Jason.encode!(%{type: "auth", token: token}) <> "\n"]
    end
  end

  # The peer token the session at `socket` published, or nil: a session writes
  # `<pid>.<sha256 of its socket path>.key` into its config directory's `sessions/`.
  defp peer_token(socket, dir \\ sessions_dir()) do
    hash = :sha256 |> :crypto.hash(socket) |> Base.encode16(case: :lower)

    with [path | _] <- Path.wildcard(Path.join(dir, "*.#{hash}.key")),
         {:ok, body} <- File.read(path),
         {:ok, %{"peerToken" => token}} when is_binary(token) <- Jason.decode(body) do
      token
    else
      _ -> nil
    end
  end

  defp sessions_dir do
    config =
      Application.get_env(:workflow, :claude_config_dir) ||
        System.get_env("CLAUDE_CONFIG_DIR") || Path.expand("~/.claude")

    Path.join(config, "sessions")
  end

  defp connect(socket),
    do: Application.get_env(:workflow, :connect, &connect_local/1).(socket)

  defp connect_local(socket) do
    :gen_tcp.connect(
      {:local, String.to_charlist(socket)},
      0,
      [:binary, active: false],
      @connect_timeout_ms
    )
  end
end
