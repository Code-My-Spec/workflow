defmodule Workflow.ManagerSessionTest do
  # Not async: the manager, its run and the works directory are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  @manager %{"agent" => %{"provider" => "claude-code"}, "repo" => "/nowhere/repo"}
  @session %{session_id: "s1", sent_upto: 2, prefix_hash: 7}

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    was = for key <- [:manager, :works_dir], do: {key, Application.get_env(:workflow, key)}
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :manager, @manager)

    on_exit(fn ->
      Workflow.Tellings.quiet()
      Application.delete_env(:workflow, :manager_run)

      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)
  end

  # The kept conversation and the session it ended in, as manager.bin holds them.
  defp kept(dir, messages, session),
    do: File.write!(Path.join(dir, "manager.bin"), :erlang.term_to_binary({messages, session}))

  defp answered(text, opts),
    do:
      {:ok,
       %{
         text: "answered",
         messages: opts[:messages] ++ [Alloy.Message.user(text), Alloy.Message.assistant("a")],
         metadata: %{provider_state: %{session_id: "s2", sent_upto: 0, prefix_hash: 1}}
       }}

  # A conversation of `n` turns, each answer `size` bytes.
  defp turns(n, size),
    do:
      Enum.flat_map(1..n, fn i ->
        [
          Alloy.Message.user("prompt #{i}"),
          Alloy.Message.assistant("#{i} " <> String.duplicate("x", size))
        ]
      end)

  test "a large kept conversation is still resumed, and Alloy is given the CLI's window",
       %{tmp_dir: dir} do
    messages = turns(60, 20_000)
    kept(dir, messages, @session)
    test = self()

    Application.put_env(:workflow, :manager_run, fn text, opts ->
      send(test, {:opts, opts})
      answered(text, opts)
    end)

    assert Workflow.Manager.tell("one more") == "answered"
    assert_received {:opts, opts}
    assert {AlloyClaudeCode, %{provider_state: @session, env: env}} = opts[:provider]
    assert {"DISABLE_AUTO_COMPACT", "1"} in env
    assert opts[:messages] == messages
    assert opts[:max_tokens] == 80_000
  end

  test "Alloy compacts a conversation past the window before it is sent" do
    {:ok, pid} =
      Alloy.Provider.Test.start_link([
        Alloy.Provider.Test.text_response("summary of the earlier turns"),
        Alloy.Provider.Test.text_response("answered")
      ])

    # About 120k tokens as Alloy counts: under its default window, over the CLI's.
    messages = turns(60, 8_000)

    {:ok, said} =
      Alloy.run("one more",
        messages: messages,
        provider: {Alloy.Provider.Test, %{agent_pid: pid}},
        max_tokens: 80_000,
        max_retries: 0
      )

    assert said.text == "answered"
    assert byte_size(:erlang.term_to_binary(said.messages)) < 400_000
  end

  test "a tool result over the cap is cut, with a note of how much" do
    # A tool whose one result is 4 MB, as an MCP server's can be.
    huge = String.duplicate("r", 4_000_000)

    tool =
      Alloy.Tool.inline(
        name: "huge",
        description: "answers 4 MB",
        input_schema: %{type: "object", properties: %{}},
        execute: fn _input, _context -> {:ok, huge} end
      )

    cap = Workflow.Manager.result_cap()
    assert {:ok, result} = Workflow.Manager.capped(tool).execute.(%{}, %{})
    assert byte_size(result) < cap + 500
    assert String.starts_with?(result, String.duplicate("r", cap))
    assert result =~ "Truncated: #{4_000_000 - cap} of 4000000 bytes cut"

    # A result under the cap is given whole.
    small = %{tool | execute: fn _input, _context -> {:ok, "small"} end}
    assert {:ok, "small"} = Workflow.Manager.capped(small).execute.(%{}, %{})
  end
end
