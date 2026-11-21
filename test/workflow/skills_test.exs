defmodule Workflow.SkillsTest do
  # Not async: the Alloy run and the settings are the whole application's.
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Agents

  defp skill(dir, name, description, body \\ "Do it this way.\n") do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: #{name}\ndescription: #{description}\n---\n#{body}"
    )

    Path.join(dir, "SKILL.md")
  end

  defp git_repo(dir) do
    File.mkdir_p!(dir)
    # The project's copy-setup and copy-teardown, as stand-ins that do nothing.
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

  defp capture_alloy do
    test = self()

    Application.put_env(:workflow, :alloy_run, fn _message, opts ->
      send(test, {:alloy_opts, opts})
      {:ok, %{status: :completed, turns: 1, messages: []}}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :alloy_run) end)
  end

  defp prompt(actor, work) do
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

  test "agent-skills: criterion 1 - an agent entry's skills: a relative folder of skill folders is read against the checkout, an absolute skill folder as it is",
       %{tmp_dir: dir} do
    root = git_repo(Path.join(dir, "checkout"))
    a = skill(Path.join(root, ".code_my_spec/skills/alpha"), "alpha", "Alpha work.")
    b = skill(Path.join(root, ".code_my_spec/skills/beta"), "beta", "Beta work.")
    c = skill(Path.join(dir, "elsewhere/gamma"), "gamma", "Gamma work.")
    capture_alloy()

    entry = %{
      "provider" => "anthropic",
      "key" => "k",
      "skills" => [".code_my_spec/skills", Path.join(dir, "elsewhere/gamma")]
    }

    said = prompt(:coder, %{"id" => "w1", "root" => root, "agents" => %{"coder" => entry}})

    for {name, path} <- [{"alpha", a}, {"beta", b}, {"gamma", c}] do
      assert said =~ name
      assert said =~ path
    end
  end

  test "agent-skills: criterion 2 - a work handed in with skills by role adds them to the settings' own for that role and that work only",
       %{tmp_dir: dir} do
    repo = git_repo(Path.join(dir, "repo"))
    skill(Path.join(repo, "skills/own"), "own", "The settings' own.")
    skill(Path.join(dir, "more/extra"), "extra", "Only this work's.")

    was = for key <- [:works_dir], do: {key, Application.get_env(:workflow, key)}
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))

    test = self()

    Application.put_env(:workflow, :agents_run, fn _step, work ->
      send(test, {:work, work})
      receive do: (:never -> {%{}, nil})
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :agents_run)
      for {key, value} <- was, do: Application.put_env(:workflow, key, value)
    end)

    coder = %{"provider" => "anthropic", "key" => "k", "skills" => ["skills/own"]}
    manager = %{"repo" => repo, "agents" => %{"coder" => coder, "reviewer" => coder}}
    hand_in = Enum.find(Workflow.Manager.tools(manager), &(&1.name == "hand_in"))
    assert hand_in.input_schema[:properties][:skills]

    issue = %{
      "kind" => "issue",
      "id" => "i1",
      "text" => "Fix it.",
      "skills" => %{"coder" => [Path.join(dir, "more/extra")]}
    }

    assert {:ok, said} = hand_in.execute.(issue, %{})
    refute said =~ "Refused"
    assert_receive {:work, work}, 5_000
    assert work["skills"] == issue["skills"]

    capture_alloy()
    root = git_repo(Path.join(dir, "root"))
    skill(Path.join(root, "skills/own"), "own", "The settings' own.")
    work = Map.merge(work, %{"root" => root, "id" => "i1-run"})

    coder_prompt = prompt(:coder, work)
    assert coder_prompt =~ "own: The settings' own."
    assert coder_prompt =~ "extra: Only this work's."

    reviewer_prompt = prompt(:reviewer, work)
    assert reviewer_prompt =~ "own: The settings' own."
    refute reviewer_prompt =~ "extra"

    # Another work, handed in without them, has only the settings' own.
    other = prompt(:coder, Map.delete(work, "skills") |> Map.put("id", "i2"))
    refute other =~ "extra"
  end

  test "agent-skills: criterion 3 - the brief ends with a line per skill and one sentence to read it, nothing else of the skill, the same for every provider",
       %{tmp_dir: dir} do
    root = git_repo(Path.join(dir, "checkout"))
    path = skill(Path.join(dir, "s/alpha"), "alpha", "Alpha work.", "SECRET BODY of the skill\n")
    capture_alloy()

    ending =
      "\n\nYour skills:\n- alpha: Alpha work. (#{path})\n" <>
        "Before doing work a skill's description covers, read its SKILL.md at the path given."

    prompts =
      for agent <- [
            %{"provider" => "anthropic", "key" => "k"},
            %{"provider" => "openai", "key" => "k", "model" => "m"},
            %{"provider" => "claude-code"}
          ] do
        agent = Map.put(agent, "skills", [Path.join(dir, "s/alpha")])
        said = prompt(:coder, %{"id" => "w", "root" => root, "agent" => agent})
        assert said == "Brief." <> ending
        refute said =~ "SECRET BODY"
        said
      end

    assert length(Enum.uniq(prompts)) == 1

    # With no skills, nothing is added.
    assert prompt(:coder, %{
             "id" => "w",
             "root" => root,
             "agent" => %{"provider" => "claude-code"}
           }) ==
             "Brief."
  end

  test "agent-skills: criterion 4 - a folder with no readable SKILL.md with a name and a description stops the boot and refuses the hand-in, naming it",
       %{tmp_dir: dir} do
    bad = Path.join(dir, "bad")
    File.mkdir_p!(bad)
    File.write!(Path.join(bad, "SKILL.md"), "---\nname: bad\n---\nNo description.\n")
    empty = Path.join(dir, "empty")
    File.mkdir_p!(empty)

    was =
      for key <- [:works_dir, :manager, :recipients],
          do: {key, Application.fetch_env(:workflow, key)}

    on_exit(fn ->
      for {key, saved} <- was do
        case saved do
          {:ok, value} -> Application.put_env(:workflow, key, value)
          :error -> Application.delete_env(:workflow, key)
        end
      end
    end)

    works = Path.join(dir, "works")
    Application.put_env(:workflow, :works_dir, works)
    config = Path.join(dir, "config.json")

    for settings <- [
          %{
            "manager" => %{
              "repo" => dir,
              "agent" => %{"provider" => "claude-code", "skills" => [bad]}
            }
          },
          %{"manager" => %{"repo" => dir, "agents" => %{"coder" => %{"skills" => ["empty"]}}}},
          %{
            "recipients" => %{
              "me" => %{"kind" => "chat", "skills" => [Path.join(dir, "nowhere")]}
            }
          }
        ] do
      File.write!(config, Jason.encode!(settings))
      assert {:error, why} = Workflow.ConfigFile.load()
      assert why =~ ~r/bad|empty|nowhere/
      assert why =~ "SKILL.md"
    end

    repo = git_repo(Path.join(dir, "repo"))
    hand_in = Enum.find(Workflow.Manager.tools(%{"repo" => repo}), &(&1.name == "hand_in"))

    assert {:ok, said} =
             hand_in.execute.(
               %{"kind" => "issue", "id" => "i9", "text" => "t", "skills" => %{"coder" => [bad]}},
               %{}
             )

    assert said =~ "Refused"
    assert said =~ bad
    refute File.exists?(Path.join(works, "i9.json"))
  end
end
