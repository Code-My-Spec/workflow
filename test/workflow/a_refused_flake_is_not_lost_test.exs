defmodule Workflow.ARefusedFlakeIsNotLostTest do
  # Not async: the manager and its run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  setup do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)
  end

  defp git!(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(out)
  end

  # The notice the manager was told as the work `id` left flight: its run, let go,
  # ends by itself, and is waited on, not on a clock.
  defp notice(id) do
    Workflow.Settled.idle()
    told(id)
  end

  defp told(id) do
    receive do
      {:told, text} when is_binary(text) ->
        if String.starts_with?(text, "issue #{id}: "), do: text, else: told(id)
    after
      0 -> flunk("no notice for #{id}")
    end
  end

  defp sarif(dir, results) do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "exunit.sarif"),
      Jason.encode!(%{
        "runs" => [%{"tool" => %{"driver" => %{"name" => "exunit"}}, "results" => results}]
      })
    )
  end

  test "a-refused-flake-is-not-lost: criteria 1 to 3 - a flake whose hand-in was refused at the cap is named, file and line, in the notice of the landing that frees a slot, until a work is handed in after it",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")
    File.write!(Path.join(repo, "justfile"), "copy-setup:\n\ncopy-teardown:\n")

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git!(repo, args)

    was = for key <- [:manager, :works_dir], do: {key, Application.get_env(:workflow, key)}
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => repo,
      "project" => "proj",
      "agents" => %{"coder" => %{"provider" => "claude-code"}},
      "cap" => 1
    })

    test = self()

    # A fake agent: it says it is at the work, and waits until let go; let go, its
    # turns end in error, so the work is parked and leaves flight.
    Application.put_env(:workflow, :agents_run, fn step, work ->
      if Process.get(:let_go) do
        {%{}, "let go"}
      else
        send(test, {:agent, step.name, work["id"], self()})

        receive do
          :go ->
            Process.put(:let_go, true)
            {%{}, "let go"}
        end
      end
    end)

    Application.put_env(:workflow, :manager_run, fn message, opts ->
      send(test, {:tools, opts[:tools]})
      send(test, {:told, message})
      {:ok, %{text: "", messages: []}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      Application.delete_env(:workflow, :manager_run)

      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Workflow.Manager.tell("go")
    assert_received {:tools, tools}
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))
    issue = fn id -> %{"kind" => "issue", "id" => id, "text" => "Fault #{id}."} end

    # The cap's one work, its agent at it.
    assert {:ok, _said} = hand_in.execute.(issue.("i1"), %{})
    assert_receive {:agent, "fix", "i1", i1}, 15_000
    # Hand-ins are kept to the second: the flake is seen after this one.
    Process.sleep(1_100)

    # A flaky tree is seen: certify failed, then passed when run again there.
    tree = Path.join([repo, ".git", "workflow", "analysis", "tflaky"])
    first = Path.join(tree, "1000")
    second = Path.join(tree, "1001")

    sarif(first, [
      %{
        "level" => "error",
        "message" => %{"text" => "test a flaky one (ATest)\nboom"},
        "locations" => [
          %{
            "physicalLocation" => %{
              "artifactLocation" => %{"uri" => "test/a_test.exs"},
              "region" => %{"startLine" => 12}
            }
          }
        ]
      }
    ])

    sarif(second, [])
    at = DateTime.utc_now() |> DateTime.to_iso8601()
    Workflow.Sarif.merge_meta(first, %{"recipe" => "certify", "exit" => 1, "at" => at})
    Workflow.Sarif.merge_meta(second, %{"recipe" => "certify", "exit" => 0, "at" => at})

    Workflow.Checkout.flaky(
      Workflow.Sarif.verdict(first, 1),
      Workflow.Sarif.verdict(second, 0)
    )

    # The manager hands in a fix for it: refused at the cap, nothing recorded.
    assert {:ok, said} = hand_in.execute.(issue.("flake"), %{})
    assert said =~ "at the cap of 1"

    # A landing frees the slot: its notice names the flaky test by file and line.
    send(i1, :go)
    told = notice("i1")
    assert told =~ "Flaky failures no work has been handed in for since they were seen:"
    assert told =~ "- test/a_test.exs:12: test a flaky one (ATest)"

    # A work is handed in for it: a later landing's notice reads as it did before.
    assert {:ok, _said} = hand_in.execute.(issue.("flake"), %{})
    assert_receive {:agent, "fix", "flake", flake}, 15_000
    send(flake, :go)
    told = notice("flake")
    refute told =~ "Flaky"
    refute told =~ "test/a_test.exs"
  end
end
