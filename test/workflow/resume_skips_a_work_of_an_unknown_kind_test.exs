defmodule Workflow.ResumeSkipsAWorkOfAnUnknownKindTest do
  # Not async: the works dir and the agent run are the whole application's.
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Workflow.Settled

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    was = for key <- [:manager, :works_dir], do: {key, Application.get_env(:workflow, key)}
    Application.delete_env(:workflow, :manager)
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    test = self()

    # A fake agent: it says which work's step it was given, and ends in error, so
    # the known work is stopped after its two tries and nothing is left running.
    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:ran, work["id"], step.name})
      {%{}, "boom"}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)

      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    :ok
  end

  defp git(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(out)
  end

  # A work in flight in a temporary git repo of its own, its works file written as the loop writes it.
  defp in_flight(dir, kind, id) do
    root = Path.join(dir, "checkout-#{id}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "hello\n")

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -q -m initial)
        ],
        do: git(root, args)

    work = %{
      "kind" => kind,
      "id" => id,
      "root" => root,
      "text" => "Fix it.",
      "agent" => %{"provider" => "claude-code"}
    }

    file = Path.join(Workflow.Run.works_dir(), "#{id}.json")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Jason.encode!(work))
    file
  end

  test "resume-skips-a-work-of-an-unknown-kind: criteria 1 and 2 - a work of an unknown kind is left alone with one warning, and the known work resumes",
       %{tmp_dir: dir} do
    # Named to sort first, so without the fix resume reaches it before the known work.
    unknown = in_flight(dir, "provision", "a-provision")
    unknown_json = File.read!(unknown)
    known = in_flight(dir, "issue", "b-known")

    log =
      capture_log(fn ->
        assert Workflow.Run.resume() == :ok
        settled()
      end)

    # The known work resumed: its agent was given its fix step, and it ran on to its stop.
    assert_received {:ran, "b-known", "fix"}
    refute File.exists?(known)

    # The unknown one was never run, and its works file is as it was.
    refute_received {:ran, "a-provision", _step}
    assert File.read!(unknown) == unknown_json

    # One warning, naming its id and its kind.
    warnings =
      log
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ "[warning]" and &1 =~ "a-provision"))

    assert [warning] = warnings, log
    assert warning =~ "provision"
    assert warning =~ ~r/kind/
  end
end
