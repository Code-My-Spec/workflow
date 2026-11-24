defmodule Workflow.AgentsTest do
  # Not async: the Alloy run is swapped for the whole application.
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Agents

  test "static-review: a reviewer's prompt carries the section, a coder's does not" do
    Application.put_env(:workflow, :cmd, fn
      "git", ["diff", "--stat", "main...HEAD"], _opts -> {" 1 file changed, 2 insertions(+)\n", 0}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    work = %{"root" => "/root"}
    snapshot = %{main: "main"}

    reviewer = %{name: "review", actor: :reviewer, note: "Review it.", agent: %{decides: true}}
    coder = %{name: "work", actor: :coder, note: "Fix it.", agent: %{}}

    assert Agents.message(reviewer, work, [], snapshot) =~ "1 file changed, 2 insertions(+)"
    refute Agents.message(coder, work, [], snapshot) =~ "1 file changed, 2 insertions(+)"
  end

  test "browser-for-pages: criterion 1 every agent of a work runs its shell commands with AGENT_BROWSER_SESSION set to the work's id",
       %{tmp_dir: dir} do
    test = self()
    # A real, empty repo: the agent's step reads what the owner said from its git dir.
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)

    # Stands in for Alloy.run, as :agents_run and :manager_run do elsewhere.
    Application.put_env(:workflow, :alloy_run, fn _message, opts ->
      send(test, {:alloy_opts, opts})
      {:ok, %{status: :completed, turns: 1, messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :alloy_run) end)

    step = %{
      name: "work",
      actor: :coder,
      note: "Fix it.",
      agent: %{tools: [:bash], brief: "Fix it."}
    }

    work = %{
      "id" => "dog-list",
      "root" => dir,
      "agent" => %{"provider" => "anthropic", "key" => "k"}
    }

    Agents.run(step, work)

    assert_receive {:alloy_opts, opts}, 1_000
    assert opts[:context][:bash_env]["AGENT_BROWSER_SESSION"] == "dog-list"
  end

  test "a work's agent resumes the Claude Code session its last step ended in", %{tmp_dir: dir} do
    test = self()
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    session = %{session_id: "s1", sent_upto: 1, prefix_hash: 7}

    Application.put_env(:workflow, :alloy_run, fn message, opts ->
      send(test, {:provider, opts[:provider]})
      kept = opts[:messages] ++ [%{role: :user, content: message}]
      {:ok, %{status: :completed, turns: 1, messages: kept, metadata: %{provider_state: session}}}
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :alloy_run)
      Agents.forget("resumed")
    end)

    step = %{name: "work", actor: :coder, note: "Fix it.", agent: %{tools: [], brief: "Fix it."}}
    work = %{"id" => "resumed", "root" => dir, "agent" => %{"provider" => "claude-code"}}

    Agents.run(step, work)
    assert_receive {:provider, {AlloyClaudeCode, first}}, 1_000
    refute Map.has_key?(first, :provider_state)

    Agents.run(step, work)
    assert_receive {:provider, {AlloyClaudeCode, %{provider_state: ^session}}}, 1_000
  end

  test "browser-for-pages: criterion 2 agents of two works see two different AGENT_BROWSER_SESSION values",
       %{tmp_dir: dir} do
    test = self()
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)

    Application.put_env(:workflow, :alloy_run, fn _message, opts ->
      send(test, {:alloy_opts, opts})
      {:ok, %{status: :completed, turns: 1, messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :alloy_run) end)

    step = %{
      name: "work",
      actor: :coder,
      note: "Fix it.",
      agent: %{tools: [:bash], brief: "Fix it."}
    }

    agent = %{"provider" => "anthropic", "key" => "k"}

    for id <- ["dog-list", "cat-list"],
        do: Agents.run(step, %{"id" => id, "root" => dir, "agent" => agent})

    assert_receive {:alloy_opts, first}, 1_000
    assert_receive {:alloy_opts, second}, 1_000

    sessions = for opts <- [first, second], do: opts[:context][:bash_env]["AGENT_BROWSER_SESSION"]
    assert Enum.sort(sessions) == ["cat-list", "dog-list"]
  end

  test "agents-commit-no-ignored-files: every agent that writes is told never to add an ignored path; one that only reads is not",
       %{tmp_dir: dir} do
    test = self()
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)

    Application.put_env(:workflow, :alloy_run, fn _message, opts ->
      send(test, {:alloy_opts, opts})
      {:ok, %{status: :completed, turns: 1, messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :alloy_run) end)

    work = %{"id" => "w", "root" => dir, "agent" => %{"provider" => "anthropic", "key" => "k"}}

    for agent <- [
          Workflow.Issue.steps() |> hd() |> Map.fetch!(:agent),
          Workflow.Parts.qa("criterion", "story")
        ] do
      Agents.run(%{name: "fix", actor: :coder, note: "Fix it.", agent: agent}, work)
      assert_receive {:alloy_opts, opts}, 1_000
      assert opts[:system_prompt] =~ "Never add a path git ignores"
    end

    reader = %{tools: [:read, :bash], brief: "Review it."}
    Agents.run(%{name: "review", actor: :reviewer, note: "Review it.", agent: reader}, work)
    assert_receive {:alloy_opts, opts}, 1_000
    refute opts[:system_prompt] =~ "ignores"
  end

  test "coder-builds-its-own-story: the QA, coder and reviewer briefs say the work is this story's criteria and nothing from another story file" do
    for brief <- [
          Workflow.Parts.qa("criterion", "story").brief,
          Workflow.Parts.coder("story").brief,
          Workflow.Parts.reviewer("story", "criteria").brief
        ] do
      assert brief =~ "Your work is this story's criteria"
      assert brief =~ "nothing from another story file"
      assert brief =~ "`stories/*.yml`"
    end
  end

  test "coder-builds-its-own-story: an agent's first message names the work's own criteria, and only then" do
    step = %{name: "work", actor: :coder, note: "Make it pass.", agent: %{}}

    work = %{
      "id" => "public-auction-page",
      "text" => "A public page",
      "criteria" => ["lists lots", "shows bids"]
    }

    first = Agents.message(step, work, [])

    assert first =~
             "This work's own criteria, and no other story's:\n1. lists lots\n2. shows bids"

    refute Agents.message(step, work, [%{role: :user, content: "before"}]) =~ "lists lots"

    # A story handed in with rules is shown one criterion per scenario.
    ruled = %{"text" => "t", "rules" => [%{"rule" => "Bids", "scenarios" => ["one wins"]}]}
    assert Agents.message(step, ruled, []) =~ "1. Bids one wins"

    # An issue has no criteria; nothing is said of them.
    refute Agents.message(step, %{"text" => "fix it"}, []) =~ "own criteria"
  end
end
