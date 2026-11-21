defmodule Workflow.PluginTest do
  # Not async: the plugin and the Alloy run are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Agents

  defp skill(dir, name) do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: #{name}\ndescription: #{name} work.\n---\nDo it.\n"
    )

    Path.join(dir, "SKILL.md")
  end

  defp git_repo(dir) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "justfile"), "copy-setup:\n\ncopy-teardown:\n")

    for args <- [
          ~w(init -q -b main),
          ~w(config user.email test@example.com),
          ~w(config user.name Test),
          ~w(add justfile),
          ~w(commit -q -m initial)
        ],
        do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

    dir
  end

  defp use_plugin(dir) do
    Application.put_env(:workflow, :plugin, dir)
    on_exit(fn -> Application.delete_env(:workflow, :plugin) end)
  end

  defp prompt(actor, work) do
    test = self()

    Application.put_env(:workflow, :alloy_run, fn _message, opts ->
      send(test, {:alloy_opts, opts})
      {:ok, %{status: :completed, turns: 1, messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :alloy_run) end)

    step = %{
      name: "work",
      actor: actor,
      note: "Do it.",
      agent: %{tools: [:read], brief: "Brief."}
    }

    Agents.run(step, work)
    assert_receive {:alloy_opts, opts}, 1_000
    opts[:system_prompt]
  end

  test "plugin-is-the-skills: criterion 2 - the coder gets the plugin's skills/coder and the qa its skills/qa, with the settings' own skills added",
       %{tmp_dir: dir} do
    plugin = Path.join(dir, "plugin")
    File.mkdir_p!(Path.join(plugin, ".claude-plugin"))
    File.write!(Path.join(plugin, ".claude-plugin/plugin.json"), ~s({"name": "p"}))
    coder = skill(Path.join(plugin, "skills/coder"), "coder")
    qa = skill(Path.join(plugin, "skills/qa"), "qa")
    extra = skill(Path.join(dir, "extra"), "extra")
    use_plugin(plugin)

    root = git_repo(Path.join(dir, "checkout"))
    entry = %{"provider" => "anthropic", "key" => "k"}

    agents = %{
      "coder" => Map.put(entry, "skills", [Path.join(dir, "extra")]),
      "qa" => entry
    }

    said = prompt(:coder, %{"id" => "p1", "root" => root, "agents" => agents})
    assert said =~ coder
    assert said =~ extra
    refute said =~ qa

    said = prompt(:qa, %{"id" => "p2", "root" => root, "agents" => agents})
    assert said =~ qa
    refute said =~ coder

    # A role the plugin has no folder for gets none of its skills.
    said = prompt(:reviewer, %{"id" => "p3", "root" => root, "agents" => %{"reviewer" => entry}})
    refute said =~ "Your skills"
  end

  test "plugin-is-the-skills: criterion 4 - the brief no longer says how to run mix; the coder skill does" do
    said = Agents.message(%{note: nil}, %{"project" => "app"}, [:said])
    assert said =~ "`app` directory"
    refute said =~ "mix"
  end
end
