defmodule Workflow.ReviewersGetThePluginEnvTest do
  # Not async: the plugin, the Alloy run and the process env are the whole application's.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Workflow.Agents
  alias Workflow.Checkout

  setup do
    plugin = Application.get_env(:workflow, :plugin)
    inherited = System.get_env("CODEMYSPEC_PLUGIN")
    # The BEAM's own env must not stand in for what the loop gives.
    System.delete_env("CODEMYSPEC_PLUGIN")

    on_exit(fn ->
      if plugin,
        do: Application.put_env(:workflow, :plugin, plugin),
        else: Application.delete_env(:workflow, :plugin)

      if inherited, do: System.put_env("CODEMYSPEC_PLUGIN", inherited)
      Application.delete_env(:workflow, :alloy_run)
    end)

    :ok
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  # What the agent's own bash tool prints for CODEMYSPEC_PLUGIN, run as Alloy runs it
  # with the context the agent's turn was given.
  defp shell_sees(opts, dir) do
    context = Map.put(opts[:context], :working_directory, dir)
    command = ~s(printf '%s' "${CODEMYSPEC_PLUGIN-unset}")
    {:ok, out} = Alloy.Tool.Core.Bash.execute(%{"command" => command}, context)
    out |> String.split("\n") |> hd()
  end

  test "reviewers-get-the-plugin-env: criterion 1 the reviewer's, coder's and qa's shells have CODEMYSPEC_PLUGIN as the configured plugin's absolute path; none without a plugin",
       %{tmp_dir: dir} do
    test = self()
    git(dir, ["init", "-q"])
    plugin = Path.join(dir, "plugin")
    File.mkdir_p!(plugin)

    Application.put_env(:workflow, :alloy_run, fn _message, opts ->
      send(test, {:alloy_opts, opts})
      {:ok, %{status: :completed, turns: 1, messages: []}}
    end)

    work = %{"id" => "w1", "root" => dir, "agent" => %{"provider" => "anthropic", "key" => "k"}}

    steps = [
      %{name: "fix", actor: :coder, note: "Fix it.", agent: %{tools: [:bash], brief: "Fix."}},
      %{
        name: "review",
        actor: :reviewer,
        note: "Review it.",
        agent: %{tools: [:read, :bash], brief: "Review.", decides: true}
      },
      %{name: "specify", actor: :qa, note: "Test it.", agent: %{tools: [:bash], brief: "QA."}}
    ]

    Application.put_env(:workflow, :plugin, plugin)

    for step <- steps do
      Agents.run(step, work)
      assert_receive {:alloy_opts, opts}, 1_000
      assert shell_sees(opts, dir) == Path.expand(plugin), "#{step.actor} lacks the plugin"
      assert opts[:context][:bash_env]["AGENT_BROWSER_SESSION"] == "w1"
    end

    Application.delete_env(:workflow, :plugin)

    for step <- steps do
      Agents.run(step, work)
      assert_receive {:alloy_opts, opts}, 1_000
      assert shell_sees(opts, dir) == "unset"
    end
  end

  test "reviewers-get-the-plugin-env: criterion 2 an agent's shell and a recipe get the plugin env from one place" do
    Application.put_env(:workflow, :plugin, "/some/plugin")
    assert Workflow.Plugin.env() == [{"CODEMYSPEC_PLUGIN", "/some/plugin"}]
    Application.delete_env(:workflow, :plugin)
    assert Workflow.Plugin.env() == []
  end

  test "reviewers-get-the-plugin-env: criterion 3 a story that landed, its file already in the main copy and its branch deleted, reads as landed after a restart, not never started",
       %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, ".code_my_spec/stories"))
    # The story's file was in the main copy before it was handed in, so the
    # work's branch has no `story s1: ...` commit of its own.
    File.write!(Path.join(repo, ".code_my_spec/stories/s1.yml"), "title: S1\n")

    for args <- [
          ~w(init -q -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -q -m initial)
        ],
        do: git(repo, args)

    git(repo, ~w(checkout -q -b story/s1))
    File.write!(Path.join(repo, "s1.txt"), "built\n")
    git(repo, ~w(add -A))
    git(repo, ["commit", "-q", "-m", "build the thing"])
    git(repo, ~w(checkout -q main))

    # What promote does and keeps, then what landing takes away.
    git(repo, ~w(merge -q --no-ff --no-edit story/s1))
    landed = git(repo, ~w(rev-parse HEAD))
    Checkout.record(repo, "s1", "promote", %{"status" => "promoted", "commit" => landed})
    git(repo, ~w(branch -q -D story/s1))

    # The restarted service: a manager made afresh from the repository, nothing in memory.
    look = Enum.find(Workflow.Manager.tools(%{"repo" => repo}), &(&1.name == "look"))
    assert {:ok, said} = look.execute.(%{"id" => "s1", "kind" => "story"}, %{})
    assert said =~ "It landed"
    refute said =~ "never started"

    # A promote result for a commit not in the main copy's history is no landing.
    Checkout.record(repo, "s2", "promote", %{
      "status" => "promoted",
      "commit" => String.duplicate("0", 40)
    })

    assert {:ok, other} = look.execute.(%{"id" => "s2", "kind" => "story"}, %{})
    assert other =~ "never started"
  end
end
