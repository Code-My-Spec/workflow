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

    case Enum.filter(Process.list(), &(&1 not in links and called_by_test?(&1))) do
      [] ->
        :ok

      pids ->
        for pid <- pids do
          ref = Process.monitor(pid)
          receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
        end

        settled()
    end
  end

  defp called_by_test?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> self() in Keyword.get(dictionary, :"$callers", [])
      nil -> false
    end
  end
end
