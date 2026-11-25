defmodule Workflow.StopKeepsTheStoryTest do
  # Not async: the manager and its run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  @path "proj/.code_my_spec/stories/s1.yml"

  @story """
  # written by the chat
  id: k3f9a2qw
  title: Invite a teammate
  story: >
    As an owner I want to invite.
  rules:
    - rule: Only an owner may invite.
      id: 7hd2k3pz
      scenarios:
        - happy: An owner invites by email and the invite is sent.
          id: x9m4c8tb
  """

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "proj/.code_my_spec/stories"))
    File.write!(Path.join([repo, "proj", "README.md"]), "hello\n")
    File.write!(Path.join(repo, @path), @story)
    File.write!(Path.join(repo, "justfile"), "copy-setup:\n\ncopy-teardown:\n")

    for args <- [
          ~w(init -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add -A),
          ~w(commit -m initial)
        ],
        do: git(repo, args)

    was = for key <- [:manager, :works_dir], do: {key, Application.get_env(:workflow, key)}
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => repo,
      "project" => "proj",
      "agents" => %{"qa" => %{"provider" => "claude-code"}}
    })

    test = self()

    # A fake agent: says it ran, then waits to be let go.
    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:agent, self(), step, work})
      receive do: (:go -> {%{}, nil})
    end)

    Application.put_env(:workflow, :manager_run, fn _message, opts ->
      send(test, {:tools, opts[:tools]})
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
    assert_receive {:tools, tools}, 5_000
    tool = fn name -> Enum.find(tools, &(&1.name == name)) end

    %{repo: repo, dir: dir, tool: tool}
  end

  defp git(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(out)
  end

  # Handed in and running its first agent turn: that agent's pid.
  defp running(tool) do
    assert {:ok, _said} = tool.("hand_in").execute.(%{"kind" => "story", "id" => "s1"}, %{})
    assert_receive {:agent, agent, _step, %{"id" => "s1"}}, 5_000
    agent
  end

  test "stop-keeps-the-story: criterion 1 - stopping a story work leaves its story file on main byte-for-byte unchanged, and no commit removing it is made",
       %{repo: repo, tool: tool} do
    _agent = running(tool)
    head = git(repo, ~w(rev-parse HEAD))
    log = git(repo, ~w(log --format=%H))

    assert {:ok, said} = tool.("stop").execute.(%{"id" => "s1", "kind" => "story"}, %{})
    assert said =~ "s1: stopped"

    assert File.read!(Path.join(repo, @path)) == @story
    assert git(repo, ["show", "HEAD:#{@path}"]) <> "\n" == @story
    assert git(repo, ~w(rev-parse HEAD)) == head
    assert git(repo, ~w(log --format=%H)) == log
    assert git(repo, ["status", "--porcelain", "--", @path]) == ""
    assert git(repo, ["log", "--diff-filter=D", "--format=%H", "--", @path]) == ""
  end

  test "stop-keeps-the-story: criterion 2 - a stopped story work never runs an agent again and never promotes, and its checkout and branch are removed",
       %{repo: repo, tool: tool} do
    agent = running(tool)
    root = Workflow.Checkout.root(repo, "s1")
    assert File.dir?(root)
    branches = git(repo, ~w(branch --list))
    assert branches =~ "s1"
    head = git(repo, ~w(rev-parse HEAD))

    assert {:ok, _said} = tool.("stop").execute.(%{"id" => "s1", "kind" => "story"}, %{})

    refute File.exists?(root)
    refute git(repo, ~w(branch --list)) =~ "s1"

    ref = Process.monitor(agent)
    send(agent, :go)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
    refute_receive {:agent, _agent, _step, %{"id" => "s1"}}, 500
    refute File.exists?(root)
    assert git(repo, ~w(rev-parse HEAD)) == head

    # Handing it in again neither runs it nor promotes it.
    assert {:ok, again} =
             tool.("hand_in").execute.(%{"kind" => "story", "id" => "s1"}, %{})

    assert again =~ "stopped for good"
    refute_receive {:agent, _agent, _step, %{"id" => "s1"}}, 500
    assert git(repo, ~w(rev-parse HEAD)) == head
    assert File.read!(Path.join(repo, @path)) == @story
  end
end
