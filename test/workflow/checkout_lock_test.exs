defmodule Workflow.CheckoutLockTest do
  use ExUnit.Case, async: true

  # The shape both locks use: {{module, key}, requester}. A lock on one key
  # shuts out another requester on the same key and nobody on a different key.
  test "a lock on one checkout leaves another checkout free" do
    id = fn key -> {{__MODULE__, key}, self()} end
    parent = self()

    :global.trans(id.("a"), fn ->
      task =
        Task.async(fn ->
          same = :global.trans({{__MODULE__, "a"}, self()}, fn -> :ran end, [node()], 0)
          other = :global.trans({{__MODULE__, "b"}, self()}, fn -> :ran end, [node()], 0)
          send(parent, {same, other})
        end)

      Task.await(task)
    end)

    assert_received {:aborted, :ran}
  end
end
