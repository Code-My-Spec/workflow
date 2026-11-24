defmodule Workflow.LoopRunsNoDevopsTest do
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

  test "loop-runs-no-devops: criteria 1 and 2 - a devops hand-in is refused naming the kind, nothing is started or recorded, and hand_in offers no devops kind, action or environment",
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

    head = git!(repo, ~w(rev-parse HEAD))
    was = for key <- [:manager, :works_dir], do: {key, Application.get_env(:workflow, key)}
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    Application.put_env(:workflow, :manager, %{
      "agent" => %{"provider" => "claude-code"},
      "repo" => repo,
      "project" => "proj",
      "agents" => %{"coder" => %{"provider" => "claude-code"}}
    })

    test = self()

    Application.put_env(:workflow, :agents_run, fn step, work ->
      send(test, {:agent, step.name, work["id"]})
      {%{}, nil}
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
    assert_received {:tools, tools}
    hand_in = Enum.find(tools, &(&1.name == "hand_in"))

    # Criterion 2: the schema offers no devops kind, and no action or environment.
    properties = hand_in.input_schema.properties
    refute "devops" in properties.kind.enum
    refute Map.has_key?(properties, :action)
    refute Map.has_key?(properties, :environment)

    # Criterion 1: refused, naming the kind, with nothing started or recorded.
    work = %{"kind" => "devops", "id" => "d1", "action" => "apply", "environment" => "uat"}
    assert {:ok, said} = hand_in.execute.(work, %{})
    assert said =~ "Refused"
    assert said =~ "devops"

    refute File.exists?(Path.join(Workflow.Run.works_dir(), "d1.json"))
    refute File.dir?(Workflow.Checkout.root(repo, "d1"))
    assert git!(repo, ~w(rev-parse HEAD)) == head
    assert git!(repo, ~w(status --porcelain)) == ""
    refute_receive {:agent, _step, "d1"}, 200
  end
end
