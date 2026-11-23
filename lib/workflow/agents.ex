defmodule Workflow.Agents do
  @moduledoc """
  One agent's step: one `Alloy.run` in the checkout, with Alloy's own tools. The
  template says what kind of agent it is; the work says what it runs on. A key
  is in that one call and kept nowhere.

  An agent lasts as long as its work: each kind of agent on a work carries on
  its own conversation from step to step, so a coder sent back by a review
  resumes where it was. When the work is done they are forgotten.
  """

  require Logger

  alias Workflow.Checkout
  alias Workflow.StaticReview

  # Said to every agent that writes, whatever its template: seen live, a scratch file
  # force-added under an ignored folder left the work dirty after the next test run.
  @writer "\n\nNever add a path git ignores: no `git add -f`, nothing under a folder .gitignore names."

  @tools %{
    read: Alloy.Tool.Core.Read,
    edit: Alloy.Tool.Core.Edit,
    write: Alloy.Tool.Core.Write,
    bash: Alloy.Tool.Core.Bash
  }

  @doc "What this kind of agent runs on: its own (`agents`, by the step's actor), else everyone's."
  @spec provider(Workflow.step(), map()) ::
          {:ok, {module(), map()}} | :none | {:error, String.t()}
  def provider(step, %{"root" => root} = work) do
    case get_in(work, ["agents", to_string(step.actor)]) || work["agent"] do
      %{"provider" => "claude-code"} = named ->
        # This machine's own `claude` login.
        config = %{model: named["model"] || "claude-sonnet-5-5", workdir: root}
        {:ok, {AlloyClaudeCode, config}}

      %{"provider" => "anthropic", "key" => "" <> key} = named ->
        config = %{api_key: key, model: named["model"] || "claude-sonnet-5-5"}
        {:ok, {Alloy.Provider.Anthropic, config}}

      %{"provider" => "openai", "key" => "" <> key, "model" => "" <> model} ->
        {:ok, {Alloy.Provider.OpenAI, %{api_key: key, model: model}}}

      %{"provider" => provider} ->
        {:error, "#{provider} is not a provider this runs, or it wants a key or a model"}

      _none ->
        :none
    end
  end

  @doc """
  Runs the step's agent to the end of its turn. Answers what it decided, else
  `%{}`, with its final text as `"said"` when it had any, and the error the run
  ended in, else `nil`.
  """
  @spec run(Workflow.step(), map()) :: {map(), term() | nil}
  def run(step, work) do
    # A skill folder that went bad since it was checked ends the step, saying so.
    case skills(step, work) do
      {:ok, skills} -> run(step, work, Workflow.Skills.brief(skills))
      {:error, why} -> {%{}, why}
    end
  end

  defp run(%{agent: agent} = step, %{"id" => id, "root" => root} = work, skills) do
    {:ok, provider} = provider(step, work)
    {:ok, decided} = Agent.start_link(fn -> %{} end)

    # shortcut: the conversations are this process's, so a restart starts every
    # agent cold; keep them with the work's results when that costs something.
    said = Agent.get(__MODULE__, &Map.get(&1, {id, step.actor}, []))
    snapshot = Checkout.snapshot(root, id)

    # `Alloy.run/2`, or what a test puts in its place.
    alloy_run = Application.get_env(:workflow, :alloy_run, &Alloy.run/2)

    # The turn, kept in the main copy's git directory as it happens.
    conversation = Workflow.Conversation.path(root, id)
    who = %{work: id, step: step.name, role: step.actor}
    prompt = message(step, work, said, snapshot)
    tools = Enum.map(agent.tools, &@tools[&1]) ++ decide(agent, decided)

    # A Claude Code agent also has the plugin's MCP servers, as Alloy runs its tools.
    tools =
      if match?({AlloyClaudeCode, _}, provider), do: tools ++ Workflow.Mcp.tools(), else: tools

    system = if(:write in agent.tools, do: agent.brief <> @writer, else: agent.brief) <> skills
    Workflow.Conversation.begun(conversation, who, system, tools)
    Workflow.Conversation.append(conversation, who, :prompt, prompt)

    result =
      alloy_run.(
        prompt,
        messages: said,
        # One agent-browser session per work, shared by its agents.
        context: %{bash_env: %{"AGENT_BROWSER_SESSION" => id}},
        provider: provider,
        tools: tools,
        # A reviewer must decide; an agent that only may is not held to it. Nil,
        # not false: Alloy holds a turn open for any tool it is given here.
        until_tool: if(agent[:decides] == true, do: "decide"),
        working_directory: root,
        system_prompt: system,
        max_retries: 0,
        # Alloy's 25 ran out on a large codebase before the coder had changed a line.
        max_turns: 200,
        on_event: fn event ->
          watch(id, step, event)
          keep(conversation, who, event)
        end
      )

    Workflow.Conversation.ended(conversation, who, length(said), result)

    review = Agent.get(decided, & &1)
    Agent.stop(decided)

    # The turn's final words, so a turn that changed nothing still says why.
    review =
      case result do
        {:ok, %{text: "" <> text}} when text != "" -> Map.put(review, "said", text)
        _no_words -> review
      end

    with {_status, %{messages: messages}} <- result,
         do: Agent.update(__MODULE__, &Map.put(&1, {id, step.actor}, messages))

    Logger.info("[Workflow #{id}] #{step.name} ended: #{outcome(result)} #{inspect(review)}")

    case result do
      {:error, %{error: error}} -> {review, error}
      _ok -> {review, nil}
    end
  end

  # This kind of agent's skills: the plugin's `skills/<role>`, its settings entry's
  # (the one it runs on), and what the work was handed in with for its role, read
  # against the checkout.
  defp skills(step, %{"root" => root} = work) do
    actor = to_string(step.actor)
    entry = get_in(work, ["agents", actor]) || work["agent"]
    own = if is_map(entry), do: entry["skills"]
    handed = if is_map(work["skills"]), do: work["skills"][actor]

    with {:ok, plugin} <- Workflow.Skills.find(Workflow.Plugin.skills(actor), root),
         {:ok, settings} <- Workflow.Skills.find(own, root),
         {:ok, more} <- Workflow.Skills.find(handed, root),
         do: {:ok, plugin ++ settings ++ more}
  end

  @doc "Forgets every agent of a work that is done."
  @spec forget(String.t()) :: :ok
  def forget(id),
    do: Agent.update(__MODULE__, &Map.reject(&1, fn {{work, _actor}, _said} -> work == id end))

  @doc "What is said to a step's agent this turn: its note, the static review section when it decides, and its own text on a first message, and where it is."
  @spec message(Workflow.step(), map(), list(), map()) :: String.t()
  def message(step, work, said, snapshot \\ %{}) do
    # The work's own text, once: after that the agent has it.
    [
      step.note,
      owner(work),
      review(step, work, snapshot),
      said == [] && work["text"],
      said == [] && own(work),
      said == [] && pinned(work),
      project(work)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  # A reviewer is held to its decision, so only a reviewer gets the static review section.
  defp review(%{agent: %{decides: true}}, work, %{} = snapshot) when map_size(snapshot) > 0 do
    case StaticReview.section(work, snapshot) do
      "" -> nil
      section -> section
    end
  end

  defp review(_step, _work, _snapshot), do: nil

  # What the owner said to the work since its last turn, whichever agent this is.
  defp owner(%{"id" => id, "root" => root}) do
    case Checkout.heard(root, id) do
      [] -> nil
      said -> Enum.join(["From the work's owner:" | said], "\n\n")
    end
  end

  defp owner(_work), do: nil

  # A story's or journey's own parts, so no agent goes to the story files for them.
  defp own(work) do
    # A story's criteria name their rule's and scenario's ids, so a test can name them.
    case work["stages"] || Workflow.StoryFile.labelled(work) do
      [_ | _] = parts ->
        word = if work["stages"], do: "stages", else: "criteria"

        story =
          case work["story_id"] do
            "" <> id when id != "" -> " (story #{id})"
            _none -> ""
          end

        lines = parts |> Enum.with_index(1) |> Enum.map(fn {part, n} -> "#{n}. #{part}" end)
        Enum.join(["This work's own #{word}#{story}, and no other story's:" | lines], "\n")

      _none ->
        nil
    end
  end

  # A story handed in at a commit is read at that commit, never on the branch,
  # which may have moved on since; one queued at a newer commit builds the difference.
  defp pinned(%{"story_at" => "" <> sha, "story_path" => "" <> path} = work) do
    at =
      "This story is as it is at commit #{sha}: read it with `git show #{sha}:#{path}`, " <>
        "never from the branch, which may have moved on."

    case work do
      %{"story_from" => "" <> from} ->
        at <>
          "\n\nYou build the difference between #{from} and #{sha}: the work at #{from} " <>
          "builds the story as it was there. `git diff #{from}..#{sha} -- #{path}` says:\n\n" <>
          (work["story_diff"] || "")

      _first ->
        at
    end
  end

  defp pinned(_work), do: nil

  # Said only of a work inside another project's checkout: there a `cd` is lost
  # between an agent's commands. How to run a tool there is the plugin's to say.
  defp project(%{"project" => "" <> project}),
    do:
      "The work is in the `#{project}` directory of this checkout. A `cd` does not carry " <>
        "between commands."

  defp project(_work), do: nil

  # A reviewer answers through this, so nothing is read out of its prose.
  defp decide(%{decides: decides} = agent, decided) when decides in [true, :may] do
    [
      Alloy.Tool.inline(
        name: "decide",
        description:
          agent[:decision] || "Record your review: pass, or fail with a note on what must change.",
        input_schema: %{
          type: "object",
          properties: %{
            decision: %{type: "string", enum: ["pass", "fail"]},
            note: %{type: "string"}
          },
          required: ["decision"]
        },
        execute: fn input, _context ->
          said = %{"status" => input["decision"], "note" => input["note"]}
          Agent.update(decided, fn _ -> said end)
          {:ok, "Recorded."}
        end
      )
    ]
  end

  defp decide(_agent, _decided), do: []

  defp outcome({:ok, result}), do: "#{result.status}, #{result.turns} turns"
  defp outcome({:error, result}), do: "failed: #{inspect(result.error)}"

  # What an agent is doing, as it does it: a line per tool call.
  defp watch(id, step, %{event: :tool_start, payload: %{name: name, input: input}}) do
    said = input |> inspect(limit: 6) |> String.slice(0, 160)
    Logger.info("[Workflow #{id}] #{step.name} #{name} #{said}")
  end

  defp watch(_id, _step, _event), do: :ok

  @doc "Appends one of Alloy's events, its payload in full, to a conversation's file."
  @spec keep(String.t() | nil, map(), term()) :: :ok
  def keep(conversation, who, %{event: event, payload: payload}),
    do: Workflow.Conversation.append(conversation, who, event, payload)

  def keep(conversation, who, event),
    do: Workflow.Conversation.append(conversation, who, :event, event)
end
