defmodule Workflow.Tellings do
  @moduledoc false
  # A work that ends tells the manager from a task of its own, which nothing in a
  # test waits on. Left running, that telling reaches the one manager in a later
  # test, with that test's manager_run (or with none, the real manager), and a
  # tell the test makes waits behind it. So a test that drives the loop calls
  # `quiet/0` at its start and end, leaving none.

  @doc """
  Leaves no telling of the manager going, and none to come: each work a test
  left going is ended, and every telling waited for. Meanwhile the manager and
  every command are stand-ins: a work ended after its test put its own back
  would run the real manager, and real git in its old checkout (or the repo
  above it).
  """
  def quiet do
    stand_ins = [
      manager_run: fn _message, opts -> {:ok, %{text: "", messages: opts[:messages]}} end,
      # What a stop keeps beside the git dir goes to a scratch folder, not the cwd.
      cmd: fn
        "git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], _opts ->
          {Path.join(System.tmp_dir!(), "workflow-tellings") <> "\n", 0}

        _command, _args, _opts ->
          {"", 0}
      end
    ]

    was = for {key, _stand_in} <- stand_ins, do: {key, Application.fetch_env(:workflow, key)}

    for {key, stand_in} <- stand_ins, do: Application.put_env(:workflow, key, stand_in)

    told()

    for {key, value} <- was do
      case value do
        {:ok, value} -> Application.put_env(:workflow, key, value)
        :error -> Application.delete_env(:workflow, key)
      end
    end
  end

  defp told do
    case Enum.filter(Process.list(), &telling?/1) do
      [] ->
        :ok

      pids ->
        for pid <- pids do
          ref = Process.monitor(pid)

          # A work's turns may be held for good in a test's stand-in agent: ended,
          # so its watch stops the work and tells that, here, under the stand-in.
          if watch?(pid), do: end_turns(pid)

          receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
        end

        told()
    end
  end

  # Every task the loop starts tells the manager, or may: its landings', ci reds',
  # reruns' and pushes' tellings, and each work's own (its copy and its watch),
  # which tells as the work stops, waits on its owner or is done. Matched by
  # module, not by name: a name follows the function that starts the task, and
  # a task moved to another function would slip past.
  defp telling?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        match?(
          {module, _name, 0} when module in [Workflow.Run, Workflow.Checkout],
          dictionary[:"$initial_call"]
        )

      nil ->
        false
    end
  end

  defp watch?(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} ->
        Enum.any?(stack, &match?({Workflow.Run, :watch, 2, _at}, &1))

      nil ->
        false
    end
  end

  # The turns a watch runs, under its monitor.
  defp end_turns(watch) do
    with {:monitors, monitors} <- Process.info(watch, :monitors) do
      for {:process, turns} <- monitors, do: Process.exit(turns, :kill)
    end
  end
end
