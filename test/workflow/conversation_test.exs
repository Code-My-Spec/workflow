defmodule Workflow.ConversationTest do
  # Not async: the Alloy run is swapped for the whole application.
  use ExUnit.Case

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias Workflow.Agents

  @step %{
    name: "work",
    actor: :coder,
    note: "Fix it.",
    agent: %{tools: [:bash], brief: "Fix it."}
  }

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  # A main copy with one commit, and the work's checkout as a linked worktree of it.
  defp main_and_checkout(dir, id) do
    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    git!(main, ~w(init -q))
    git!(main, ~w(-c user.name=t -c user.email=t@t commit -q --allow-empty -m first))
    checkout = Path.join(dir, id)
    git!(main, ["worktree", "add", "-q", "-b", id, checkout])
    {main, checkout}
  end

  defp work(id, root),
    do: %{"id" => id, "root" => root, "agent" => %{"provider" => "anthropic", "key" => "k"}}

  defp stub(fun) do
    Application.put_env(:workflow, :alloy_run, fun)
    on_exit(fn -> Application.delete_env(:workflow, :alloy_run) end)
  end

  defp lines(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  test "conversations-jsonl: a turn with one tool call leaves its prompt, the call in full, the result and the closing words, in order, and they outlive the checkout",
       %{tmp_dir: dir} do
    {main, checkout} = main_and_checkout(dir, "dog-list")
    command = String.duplicate("echo long; ", 40)

    stub(fn prompt, opts ->
      on_event = opts[:on_event]

      on_event.(%{
        v: 1,
        event: :tool_start,
        payload: %{id: "t1", name: "bash", input: %{"command" => command}}
      })

      on_event.(%{v: 1, event: :tool_end, payload: %{id: "t1", name: "bash", error: nil}})

      messages = [
        %{role: :user, content: prompt},
        %{role: :assistant, content: [%{type: "tool_use", id: "t1", name: "bash", input: %{}}]},
        %{role: :user, content: [%{type: "tool_result", tool_use_id: "t1", content: "long"}]},
        %{role: :assistant, content: [%{type: "text", text: "I stopped: no commit."}]}
      ]

      {:ok, %{status: :completed, turns: 2, text: "I stopped: no commit.", messages: messages}}
    end)

    Agents.run(@step, work("dog-list", checkout))

    git!(main, ["worktree", "remove", "--force", checkout])
    refute File.exists?(checkout)

    path = Path.join([main, ".git", "workflow", "conversations", "dog-list.jsonl"])
    lines = lines(path)
    events = Enum.map(lines, & &1["event"])

    assert events == [
             "system",
             "prompt",
             "tool_start",
             "tool_end",
             "assistant",
             "tool_result",
             "assistant",
             "closing"
           ]

    for line <- lines do
      assert %{"work" => "dog-list", "step" => "work", "role" => "coder", "ts" => ts} = line
      assert {:ok, _at, 0} = DateTime.from_iso8601(ts)
    end

    [_system, prompt, call, _end, _assistant, result, _last, closing] = lines
    assert prompt["payload"] =~ "Fix it."
    assert call["payload"]["input"]["command"] == command
    assert [%{"type" => "tool_result", "content" => "long"}] = result["payload"]["content"]
    assert closing["payload"]["text"] == "I stopped: no commit."

    # In the git directory, so never in a commit.
    assert git!(main, ~w(status --porcelain)) == ""
  end

  test "conversations-are-whole: a turn with one tool call leaves, in order, the system prompt, the call, its output text, the assistant's words and the closing message",
       %{tmp_dir: dir} do
    {main, checkout} = main_and_checkout(dir, "whole")
    test = self()

    stub(fn prompt, opts ->
      send(test, {:system_prompt, opts[:system_prompt]})
      on_event = opts[:on_event]
      on_event.(%{v: 1, event: :tool_start, payload: %{id: "t1", name: "bash", input: %{}}})
      # Alloy's tool_end carries no output: that is only in the messages.
      on_event.(%{v: 1, event: :tool_end, payload: %{id: "t1", name: "bash", error: nil}})

      messages = [
        Alloy.Message.user(prompt),
        Alloy.Message.assistant_blocks([
          %{type: "thinking", thinking: "List the files first.", signature: "s"},
          %{type: "text", text: "Looking at the files."},
          %{type: "tool_use", id: "t1", name: "bash", input: %{"command" => "ls"}}
        ]),
        %Alloy.Message{
          role: :user,
          content: [Alloy.Message.tool_result_block("t1", "mix.exs\nlib\n")]
        },
        Alloy.Message.assistant("Done: committed.")
      ]

      {:ok, %{status: :completed, turns: 2, text: "Done: committed.", messages: messages}}
    end)

    Agents.run(@step, work("whole", checkout))
    assert_received {:system_prompt, system_prompt}

    lines = lines(Path.join([main, ".git", "workflow", "conversations", "whole.jsonl"]))

    assert Enum.map(lines, & &1["event"]) == [
             "system",
             "prompt",
             "tool_start",
             "tool_end",
             "assistant",
             "tool_result",
             "assistant",
             "closing"
           ]

    [system, _prompt, call, _end, words, output, last, closing] = lines
    assert system["payload"] == %{"system_prompt" => system_prompt, "tools" => ["bash"]}
    assert system_prompt =~ "Fix it."
    assert call["payload"]["name"] == "bash"

    assert [
             %{"type" => "thinking", "thinking" => "List the files first."},
             %{"type" => "text", "text" => "Looking at the files."},
             %{"type" => "tool_use", "input" => %{"command" => "ls"}}
           ] = words["payload"]["content"]

    assert [%{"type" => "tool_result", "content" => "mix.exs\nlib\n"}] =
             output["payload"]["content"]

    assert last["payload"]["content"] == "Done: committed."
    assert closing["payload"]["text"] == "Done: committed."
  end

  test "conversations-jsonl: look answers the path of the work's conversation", %{tmp_dir: dir} do
    {_main, checkout} = main_and_checkout(dir, "dog-list")

    seen = Workflow.Run.look(%{"kind" => "issue", "id" => "dog-list", "root" => checkout})

    # The main copy's git directory, not the checkout's (a tmp path may be read through a symlink).
    assert String.ends_with?(
             seen.conversation,
             "/main/.git/workflow/conversations/dog-list.jsonl"
           )
  end

  test "conversations-jsonl: a payload that will not encode is written as its inspect string",
       %{tmp_dir: dir} do
    {main, checkout} = main_and_checkout(dir, "w")
    odd = %{pid: self(), pair: {:a, 1}}

    stub(fn _prompt, opts ->
      opts[:on_event].(%{v: 1, event: :runtime_event, payload: odd})
      {:ok, %{status: :completed, turns: 1, messages: []}}
    end)

    Agents.run(@step, work("w", checkout))

    lines = lines(Path.join([main, ".git", "workflow", "conversations", "w.jsonl"]))
    assert %{"payload" => said} = Enum.find(lines, &(&1["event"] == "runtime_event"))
    assert said == inspect(odd, limit: :infinity, printable_limit: :infinity)
  end

  test "conversations-jsonl: a write that fails is logged and the turn still runs to its end",
       %{tmp_dir: dir} do
    {main, checkout} = main_and_checkout(dir, "w")
    test = self()

    # A file where the conversations folder should be: nothing can be written under it.
    File.mkdir_p!(Path.join([main, ".git", "workflow"]))
    File.write!(Path.join([main, ".git", "workflow", "conversations"]), "")

    stub(fn _prompt, opts ->
      opts[:on_event].(%{v: 1, event: :tool_start, payload: %{id: "t", name: "bash", input: %{}}})
      send(test, :ran)
      {:ok, %{status: :completed, turns: 1, messages: []}}
    end)

    log = capture_log(fn -> assert {%{}, nil} = Agents.run(@step, work("w", checkout)) end)

    assert_received :ran
    assert log =~ "not written"
    # The service-log line is still said.
    assert log =~ "[Workflow w] work bash"
  end
end
