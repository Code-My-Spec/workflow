defmodule Workflow.Settled do
  @moduledoc false
  # `Workflow.Run.start/1` answers once it has started a work's watch in the
  # background; the agent stand-in is called later, from the turns. A test that
  # gave that a receive deadline or a sleep failed on a loaded machine, so it
  # waits on the run itself, then checks what it was sent with assert_received.

  @doc """
  Waits until every process a call in this test left running in the background
  (a work's turns, their watcher, a resume) has gone down. Each says who started
  it in `$callers`; one linked to the test lives as long as the test, so is not waited on.
  """
  def settled do
    {:links, links} = Process.info(self(), :links)
    gone(fn -> Enum.filter(Process.list(), &(&1 not in links and called_by_test?(&1))) end)
  end

  @doc """
  Waits until nothing the loop started is running: as `settled/0`, and also what
  it cannot see, since the turns run under spawn_monitor, which drops `$callers`:
  the tasks a work's turns start (its telling of the manager),
  a checkout's own tellings and pushes, and a step's report to the server. Only for a test whose runs all end by
  themselves; one held in a stand-in agent is waited on for good.
  """
  def idle do
    settled()
    gone(fn -> Enum.filter(Process.list(), &loop?/1) end)
  end

  defp gone(running) do
    case running.() -- [self()] do
      [] ->
        :ok

      pids ->
        for pid <- pids do
          ref = Process.monitor(pid)
          receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
        end

        gone(running)
    end
  end

  defp called_by_test?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> self() in Keyword.get(dictionary, :"$callers", [])
      nil -> false
    end
  end

  # Matched by module, as Workflow.Tellings matches them, with a recorded step's
  # report to the server.
  defp loop?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        match?(
          {module, _name, 0} when module in [Workflow.Run, Workflow.Checkout, Workflow.Report],
          dictionary[:"$initial_call"]
        )

      nil ->
        false
    end
  end
end
