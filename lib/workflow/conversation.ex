defmodule Workflow.Conversation do
  @moduledoc """
  Every agent turn the loop runs, appended as it happens to one JSONL file in the
  main copy's git directory: `<git common dir>/workflow/conversations/<name>.jsonl`.
  There it outlives a work's checkout and is never committed. One JSON object a
  line, never rewritten. A write that fails is logged and never stops the turn.
  """

  require Logger

  @doc "The file `name`'s conversation is kept in, for any checkout of `dir`'s repository; nil outside one."
  @spec path(String.t() | nil, String.t()) :: String.t() | nil
  def path("" <> dir, name) do
    if File.dir?(dir) do
      case Workflow.Checkout.cmd(
             "git",
             ~w(rev-parse --path-format=absolute --git-common-dir),
             [cd: dir, stderr_to_stdout: true],
             &System.cmd/3
           ) do
        {git_dir, 0} ->
          Path.join([String.trim(git_dir), "workflow", "conversations", "#{name}.jsonl"])

        _not_git ->
          nil
      end
    end
  end

  def path(_dir, _name), do: nil

  @doc """
  Appends one line: ts (UTC), work, step, role, the event's name and its payload
  in full. A payload that will not encode is written as its inspect string.
  """
  @spec append(String.t() | nil, map(), atom() | String.t(), term()) :: :ok
  def append(path, who, event, payload)

  def append(nil, _who, _event, _payload), do: :ok

  def append(path, who, event, payload) do
    line = %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      work: who[:work],
      step: who[:step],
      role: who[:role] && to_string(who[:role]),
      event: to_string(event),
      payload: payload
    }

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, encode(line) <> "\n", [:append]) do
      :ok
    else
      {:error, why} ->
        Logger.warning("[Workflow] conversation #{path} not written: #{inspect(why)}")
    end
  rescue
    error -> Logger.warning("[Workflow] conversation #{path} not written: #{inspect(error)}")
  end

  @doc """
  A turn's first line: the system prompt in full and the names of the tools it
  was given.
  """
  @spec begun(String.t() | nil, map(), String.t(), list()) :: :ok
  def begun(path, who, system_prompt, tools) do
    names = Enum.map(tools, &Alloy.Tool.Registry.to_inline(&1).name)
    append(path, who, :system, %{system_prompt: system_prompt, tools: names})
  rescue
    error -> Logger.warning("[Workflow] conversation #{path} not written: #{inspect(error)}")
  end

  @doc """
  What a run left once it ended, after its prompt and tool events: each message
  it added (an assistant's, or a tool's result), then its closing words.
  `before` is how many messages it was given, its prompt not counted.
  """
  @spec ended(String.t() | nil, map(), non_neg_integer(), term()) :: :ok
  def ended(path, who, before, result) do
    said = with {_status, %{} = run} <- result, do: run, else: (_other -> %{})
    messages = (Map.get(said, :messages) || []) |> Enum.drop(before + 1)

    for message <- messages, do: append(path, who, kind(message), plain(message))

    append(path, who, :closing, %{
      status: Map.get(said, :status),
      turns: Map.get(said, :turns),
      text: Map.get(said, :text),
      error: Map.get(said, :error)
    })
  end

  defp kind(message) do
    content = Map.get(message, :content)

    cond do
      is_list(content) and Enum.any?(content, &match?(%{type: "tool_result"}, &1)) -> :tool_result
      to_string(Map.get(message, :role)) == "assistant" -> :assistant
      true -> :message
    end
  end

  defp plain(%_struct{} = message), do: Map.from_struct(message)
  defp plain(message), do: message

  defp encode(line) do
    case safe(line) do
      {:ok, json} ->
        json

      :error ->
        line
        |> Map.update!(:payload, &inspect(&1, limit: :infinity, printable_limit: :infinity))
        |> Jason.encode!()
    end
  end

  defp safe(line) do
    case Jason.encode(line) do
      {:ok, json} -> {:ok, json}
      {:error, _why} -> :error
    end
  rescue
    _unencodable -> :error
  end
end
