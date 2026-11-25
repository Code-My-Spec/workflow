defmodule Workflow.ManagerSessionBoundedTest do
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

  # A fake run: tells the test what it was given, and answers what `answer` says.
  defp run(answer) do
    test = self()

    Application.put_env(:workflow, :manager_run, fn text, opts ->
      {_module, config} = opts[:provider]
      send(test, {:ran, Map.get(config, :provider_state), opts[:messages]})
      answer.(text, opts, Map.has_key?(config, :provider_state))
    end)
  end

  defp answered(text, opts),
    do:
      {:ok,
       %{
         text: "answered",
         messages: opts[:messages] ++ [Alloy.Message.user(text), Alloy.Message.assistant("a")],
         metadata: %{provider_state: %{session_id: "s2", sent_upto: 0, prefix_hash: 1}}
       }}

  defp too_long(opts),
    do:
      {:error,
       %{error: "claude exec failed with status 1: Prompt is too long", messages: opts[:messages]}}

  test "manager-session-unbounded: criterion 1 - a kept conversation past the bound starts a fresh session from the bounded conversation",
       %{tmp_dir: dir} do
    big = String.duplicate("x", 20_000)

    messages =
      Enum.flat_map(1..60, fn n ->
        [Alloy.Message.user("prompt #{n}"), Alloy.Message.assistant("#{n} #{big}")]
      end)

    assert byte_size(:erlang.term_to_binary(messages)) > Workflow.Manager.bound()
    kept(dir, messages, @session)
    run(fn text, opts, _resumed -> answered(text, opts) end)

    assert Workflow.Manager.tell("one more") == "answered"

    # Not resumed: fresh, from the newest turns that fit the bound.
    assert_received {:ran, nil, [%{role: :user, content: "prompt " <> _} | _] = given}
    assert byte_size(:erlang.term_to_binary(given)) <= Workflow.Manager.bound()
    assert List.last(given) == List.last(messages)
    refute_received {:ran, _, _}
  end

  test "manager-session-unbounded: criterion 2 - a turn refused as too long is retried once, fresh from the bounded conversation",
       %{tmp_dir: dir} do
    messages = [Alloy.Message.user("one"), Alloy.Message.assistant("ok")]
    kept(dir, messages, @session)

    # The resumed session is past the CLI's context; a fresh one is not.
    run(fn text, opts, resumed -> if resumed, do: too_long(opts), else: answered(text, opts) end)

    assert Workflow.Manager.tell("two") == "answered"
    assert_received {:ran, @session, ^messages}
    assert_received {:ran, nil, ^messages}
    refute_received {:ran, _, _}

    # The fresh session is the one kept for the next turn.
    assert {_kept, %{session_id: "s2"}} =
             :erlang.binary_to_term(File.read!(Path.join(dir, "manager.bin")))
  end

  test "manager-session-unbounded: criterion 2 - a fresh retry refused again is reported, not looped",
       %{tmp_dir: dir} do
    kept(dir, [Alloy.Message.user("one"), Alloy.Message.assistant("ok")], @session)
    run(fn _text, opts, _resumed -> too_long(opts) end)

    assert Workflow.Manager.tell("two") =~ "Prompt is too long"
    assert_received {:ran, @session, _}
    assert_received {:ran, nil, _}
    refute_received {:ran, _, _}
  end

  test "manager-session-unbounded: criterion 3 - a tool result over the cap is cut, with a note of how much" do
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
