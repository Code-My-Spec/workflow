defmodule Workflow.Manager do
  @moduledoc """
  The project manager: the one agent that outlives a work. It is told things,
  one message at a time, and can do six: hand a work in, record a story without
  building it, decide for a work's owner, look at a work, tell a running work something,
  and stop a work for good. It does not code, review, test or read the
  repository; a work's own agents do.

  It exists only where `:manager` is configured: a map of the `"repo"` its works
  are cut from (work lands not there but in the repository's primary checkout,
  the first line of `git worktree list`, on whatever branch it has, even when
  `"repo"` names a linked worktree of it; the manager is told that folder and branch), and optionally the `"agent"` it runs on, the `"project"`, the
  `"agents"` its works run on, and the `"cap"` on works in flight (default 3).
  With no `"agent"` the service runs no manager turns: its tools are still
  offered on POST /mcp/manager, and what is said to it is delivered by its
  recipient kind (see `Workflow.Messages`).
  """

  alias Workflow.Agents
  alias Workflow.Checkout
  alias Workflow.Run

  @brief """
  You are the project manager for one repository. You are told things; you do not go looking.

  Requests arrive already interviewed: the person has been asked who it is for, what they \
  should be able to do, and two to four things that would show it works, and their answers \
  come with the request. Write the criteria from what you are given. Ask back, in your reply, \
  only when something a test would need is missing; never invent it.

  When you are told of something to build or a fault to fix, write it up as a work (a clear, \
  complete text: what is wanted, where, how it will be checked) and hand it in: an issue for a \
  fault, a story for something new. A criterion is something the product does that a test can \
  show, never an instruction to the agents (run this, cover that): those belong in the text. \
  Most stories have two to four.

  Write a request up as rules and scenarios: a title, the workflow it belongs to, the story \
  (who wants what, and why), and its business rules, each with a happy or failing scenario \
  under it. Each scenario becomes a criterion. Record anything unsettled as questions; never \
  guess an answer. Hand in a story that still has open questions only when the person says to \
  go ahead anyway.

  Record every story the person settles, and hand in only what they ask to have built.

  When the chat passes personas on, record them (with their research text, if any).

  When a work is done, say so in one line. When a work waits on its owner, do not decide for \
  the owner unless the owner has told you how; say what is waiting. When a work is stopped, look \
  at it once and say plainly why it stopped and that it needs a person. Hand a stopped work in \
  again only when you are told to.

  Nobody waits on your answer to a message from the loop: the owner reads it later, so say \
  what you did or exactly what a person must do.

  A push the box refuses or fails is a failure of this app, and yours to act on at once: hand \
  in an issue with the failure's text, without asking anyone. The loop is not a person and will \
  not say go ahead. Ask only about what a person must decide.

  A failure of the loop itself (a record refused because the main copy has uncommitted changes, \
  a step sent back three times with the same tree and note) is not a fault in this app, and no \
  coder here can fix it: tell the person in plain words and never hand it in as an issue in this \
  app. Hand in an issue only for a failure of the app's own code or checks.

  Work that passes lands in the repository's primary checkout on this machine, on whatever \
  branch it has checked out, even when the repo you were given is a linked worktree of it. \
  Name that landing target (its folder and branch) to the person before the first work you \
  hand in, and whenever you are asked where work lands.

  You never write code and never read the repository. Keep every reply to a few lines.
  """

  @doc "The manager as configured, or nil when there is none."
  @spec configured() :: map() | nil
  def configured, do: Application.get_env(:workflow, :manager)

  @doc "Gives the manager one message and answers what it said back; nil with no manager."
  @spec tell(String.t()) :: String.t() | nil
  def tell(text) do
    # One message at a time: each is run in this module's own process, so a
    # second waits for the first. Not `:global.trans`: its retries back off at
    # random, and a second message sat for seconds after the first was done.
    if manager = configured(),
      do: Agent.get(__MODULE__, fn nil -> said(manager, text) end, :infinity)
  end

  defp said(manager, text) do
    File.mkdir_p!(home())

    with {:ok, provider} <-
           Agents.provider(%{actor: :manager}, %{"root" => home(), "agent" => manager["agent"]}),
         {:ok, plugin} <- Workflow.Skills.find(Workflow.Plugin.skills(:manager), repo(manager)),
         {:ok, own} <-
           Workflow.Skills.find(get_in(manager, ["agent", "skills"]), repo(manager)),
         skills = plugin ++ own do
      messages = remembered()
      conversation = Workflow.Conversation.path(manager["repo"], "manager")
      who = %{work: nil, step: nil, role: :manager}
      tools = tools(manager)
      system = @brief <> landing(manager) <> Workflow.Skills.brief(skills)
      Workflow.Conversation.begun(conversation, who, system, tools)
      Workflow.Conversation.append(conversation, who, :prompt, text)

      result =
        run(text,
          messages: messages,
          provider: provider,
          tools: tools,
          working_directory: home(),
          system_prompt: system,
          max_retries: 0,
          on_event: &Agents.keep(conversation, who, &1)
        )

      Workflow.Conversation.ended(conversation, who, length(messages), result)

      case result do
        {:ok, said} ->
          remember(said.messages)
          said.text || ""

        {:error, said} ->
          "The manager's run ended in error: #{inspect(said.error)}"
      end
    else
      :none -> "The manager has no agent configured to run on."
      {:error, reason} -> "The manager cannot run: #{reason}"
    end
  end

  # The landing target, as the manager sees it: folder and branch, read each turn.
  defp landing(manager) do
    case Checkout.landing(manager["repo"]) do
      %{folder: folder, branch: branch} ->
        "\nThe landing target: work lands in #{folder}, on the branch #{branch}.\n"

      nil ->
        "\nThe landing target is unknown: #{inspect(manager["repo"])} is not a git checkout.\n"
    end
  end

  # What a relative skill folder is read against when there is no work's checkout yet.
  defp repo(%{"repo" => "" <> repo}), do: repo
  defp repo(_manager), do: File.cwd!()

  # Beside the works directory, so `~/.workflow/manager.bin` by default.
  defp home, do: Path.dirname(Run.works_dir())

  # Alloy's messages are structs, which do not encode as JSON: they are kept as
  # Erlang terms, written and read only here.
  defp file, do: Path.join(home(), "manager.bin")

  defp remembered do
    case File.read(file()) do
      {:ok, kept} -> :erlang.binary_to_term(kept)
      {:error, _none} -> []
    end
  end

  # shortcut: the whole conversation is kept and sent every time, so it grows
  # without end; cut it down when a manager has lived long enough to fill its context.
  defp remember(messages), do: File.write!(file(), :erlang.term_to_binary(messages))

  @doc """
  The manager's own tools (hand_in, record, decide, look, tell, stop) for the given
  manager settings: what its turns run with, and what POST /mcp/manager offers.
  """
  @spec tools(map()) :: [Alloy.Tool.Inline.t()]
  def tools(manager),
    do: [
      hand_in(manager),
      record(manager),
      decide(manager),
      look(manager),
      told(manager),
      stop(manager)
    ]

  # Stops a work for good: no agent runs on it again and it never promotes; its
  # checkout and branch are taken away, and its story or issue file is removed
  # from the main copy in a commit of its own.
  defp stop(manager) do
    Alloy.Tool.inline(
      name: "stop",
      description:
        "Stop a work for good: no agent runs on it again and it never promotes. Its " <>
          "checkout and branch are removed, and its story or issue file is removed from " <>
          "the main copy, committed.",
      input_schema: %{
        type: "object",
        properties: %{id: %{type: "string"}, kind: %{type: "string", enum: Run.kinds()}},
        required: ["id", "kind"]
      },
      execute: fn %{"id" => "" <> id, "kind" => "" <> kind}, _context ->
        repo = manager["repo"]

        if is_binary(repo) and File.exists?(Path.join(repo, ".git")) do
          work = Map.merge(%{"kind" => kind, "id" => id}, configured_for(manager))
          Run.cancel(work)
          # Where its file is kept: a story's or journey's as one handed in with a text.
          path =
            if kind == "issue",
              do: Workflow.StoryFile.issue_path(work),
              else: Workflow.StoryFile.path(Map.put(work, "text", ""))

          case Checkout.remove_files(repo, [path], "#{kind} #{id}: stopped, its file removed") do
            {:error, why} -> {:ok, "#{id}: stopped, but #{path} not removed: #{inspect(why)}"}
            _removed -> {:ok, "#{id}: stopped. Its checkout, branch and file are removed."}
          end
        else
          {:ok, "Refused: #{inspect(repo)} is not a git checkout. Nothing was stopped."}
        end
      end
    )
  end

  # Says something to a running work, as POST /work/say does.
  defp told(manager) do
    Alloy.Tool.inline(
      name: "tell",
      description:
        "Say something to a running work: it reaches the work's next agent turn, as from " <>
          "its owner, without interrupting a turn already running.",
      input_schema: %{
        type: "object",
        properties: %{id: %{type: "string"}, say: %{type: "string"}},
        required: ["id", "say"]
      },
      execute: fn %{"id" => "" <> id, "say" => "" <> said}, _context ->
        case Checkout.say_to(root(manager, id), id, said) do
          :ok -> {:ok, "#{id}: told."}
          _none -> {:ok, "There is no work #{id} running."}
        end
      end
    )
  end

  @recorded ~w(id title workflow story rules questions)

  defp record(manager) do
    Alloy.Tool.inline(
      name: "record",
      description:
        "Record a settled story in the main copy (stories/<id>.yml and its workflow file), " <>
          "committed, without starting any work.",
      input_schema: %{
        type: "object",
        properties:
          story_properties()
          |> Map.take([:id, :title, :workflow, :story, :rules, :questions])
          |> Map.put(:personas, persona_properties())
      },
      execute: fn
        %{"personas" => personas}, _context when is_list(personas) ->
          record_personas(personas, manager)

        input, _context ->
          record_story(input, manager)
      end
    )
  end

  @persona_fields ~w(name main wants today uses refuses pays guess)

  defp persona_properties do
    fields = Map.new(@persona_fields ++ ["research"], &{&1, %{type: "string"}})
    %{type: "array", items: %{type: "object", properties: fields, required: ["name"]}}
  end

  # personas.yml in the main copy's project, with personas/<name>.md for each
  # persona given research, all in one commit, starting no work.
  defp record_personas(personas, manager) do
    repo = manager["repo"]
    dir = manager["project"] || "."
    path = Path.join(dir, "personas.yml") |> Path.relative()

    cond do
      Enum.any?(personas, &(not is_map(&1) or blank?(&1["name"]))) ->
        {:ok, "Refused: every persona needs a name, and one has none. Nothing was recorded."}

      Checkout.changed?(repo, path) ->
        {:ok, "Refused: #{path} has uncommitted changes in the main copy. Nothing was recorded."}

      true ->
        research =
          for %{"research" => text, "name" => name} <- personas,
              not blank?(text),
              do: {Path.join([dir, "personas", "#{name}.md"]) |> Path.relative(), text}

        files = [{path, personas_yaml(personas)} | research]

        case Checkout.commit_files(repo, files, "personas: as recorded") do
          :ok -> {:ok, "Personas recorded in #{path}."}
          :unchanged -> {:ok, "Personas already recorded as they are, in #{path}."}
          {:error, why} -> {:ok, "Personas not recorded: #{inspect(why)}"}
        end
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  # By hand: a JSON string is a YAML double-quoted scalar.
  defp personas_yaml(personas) do
    Enum.map_join(personas, fn persona ->
      @persona_fields
      |> Enum.filter(&is_binary(persona[&1]))
      |> Enum.with_index()
      |> Enum.map_join(fn {field, i} ->
        "#{if i == 0, do: "- ", else: "  "}#{field}: #{Jason.encode!(persona[field])}\n"
      end)
    end)
  end

  defp record_story(input, manager) do
    if Enum.any?(~w(id title story), &blank?(input[&1])),
      do: {:ok, "Refused: a story needs an id, a title and a story. Nothing was recorded."},
      else: record_story!(input, manager)
  end

  defp record_story!(input, manager) do
    repo = manager["repo"]

    work =
      input
      |> Map.take(@recorded)
      |> Map.put("kind", "story")
      |> Map.merge(Map.take(configured_for(manager), ["project"]))

    path = Workflow.StoryFile.path(work)
    yaml = Workflow.StoryFile.yaml(work)

    # A person's own edit is refused; the same story left written by a failed
    # record is not, and is committed now.
    if Checkout.changed?(repo, path) and File.read(Path.join(repo, path)) != {:ok, yaml} do
      {:ok, "Refused: #{path} has uncommitted changes in the main copy. Nothing was recorded."}
    else
      files = [{path, yaml} | Workflow.StoryFile.workflow_file(work, repo)]

      case Checkout.commit_files(repo, files, "story #{work["id"]}: the story as recorded") do
        :ok -> {:ok, "#{work["id"]}: recorded in #{path}."}
        :unchanged -> {:ok, "#{work["id"]}: already recorded as it is, in #{path}."}
        {:error, why} -> {:ok, "#{work["id"]}: not recorded: #{inspect(why)}"}
      end
    end
  end

  # What a work is handed in with: the old text and criteria (a journey's stages),
  # or a story's own shape.
  @handed_in ~w(kind id text criteria stages title workflow story rules questions target skills)

  defp hand_in(manager) do
    Alloy.Tool.inline(
      name: "hand_in",
      description:
        "Hand a work in: an issue (with text) for a fault, a story for something new (with " <>
          "title, workflow, story, rules with their scenarios, and questions), a journey " <>
          "(with stages).",
      input_schema: %{
        type: "object",
        properties:
          Map.put(story_properties(), :skills, %{
            type: "object",
            description:
              "More skill folders for this work only, by role (coder, reviewer, ...): " <>
                "each a folder holding a SKILL.md, or a folder of such folders",
            additionalProperties: %{type: "array", items: %{type: "string"}}
          }),
        required: ["kind", "id"]
      },
      execute: fn input, _context ->
        cap = manager["cap"] || 3
        flying = length(Path.wildcard(Path.join(Run.works_dir(), "*.json")))

        cond do
          # Refused before anything is recorded or started: nothing is left behind.
          flying >= cap ->
            {:ok,
             "Refused: #{flying} works are in flight, at the cap of #{cap}. Nothing was " <>
               "started and nothing is queued; hand it in again when a slot frees."}

          # Stopped for good: nothing of it, its file included, comes back.
          Checkout.cancelled?(manager["repo"], input["id"]) ->
            {:ok, "#{input["id"]}: it was stopped for good, and never runs again."}

          refused = skills_refused(input["skills"], manager) ->
            {:ok, "Refused: #{elem(refused, 1)}. Nothing was started."}

          true ->
            work = input |> Map.take(@handed_in) |> Map.merge(configured_for(manager))

            case by_id(work, manager) do
              {:refused, said} ->
                {:ok, said}

              work ->
                case issue_recorded(work, manager) do
                  {:refused, said} -> {:ok, said}
                  note -> with {:ok, said} <- started(work), do: {:ok, said <> note}
                end
            end
        end
      end
    )
  end

  # A work's own skills, by role, each folder read against the repo: the error
  # naming the first folder that is not a skill, else nil.
  defp skills_refused(nil, _manager), do: nil

  defp skills_refused(%{} = by_role, manager) do
    Enum.find_value(by_role, fn {_role, folders} ->
      with {:ok, _skills} <- Workflow.Skills.find(folders, repo(manager)), do: nil
    end)
  end

  defp skills_refused(other, _manager),
    do: {:error, "skills must be a map of role to folders, not #{inspect(other)}"}

  # A story handed in by its id alone is built from what was recorded for it in
  # the main copy: unchanged, its file makes no second commit in the work.
  defp by_id(%{"kind" => "story"} = work, manager) do
    if id_alone?(work) do
      case Workflow.StoryFile.recorded(work, manager["repo"]) do
        {:ok, recorded} ->
          recorded
          |> Map.put("criteria", Workflow.StoryFile.criteria(recorded))
          |> Map.merge(work)

        {:none, path} ->
          {:refused,
           "Refused: no story #{work["id"]} is recorded (there is no #{path} in the main " <>
             "copy). Record it first, or hand it in whole."}
      end
    else
      work
    end
  end

  # A journey too, its stages included; its recorded file is not written over by
  # one handed in with fields, and one handed in whole needs stages.
  defp by_id(%{"kind" => "journey", "id" => id} = work, manager) do
    recorded =
      if is_binary(manager["repo"]),
        do: Workflow.StoryFile.recorded(work, manager["repo"]),
        else: {:none, "stories/#{id}.yml"}

    case {id_alone?(work), recorded} do
      {true, {:ok, journey}} ->
        journey |> Map.merge(work) |> Map.put("recorded", true) |> with_stages()

      {true, {:none, path}} ->
        {:refused,
         "Refused: no journey #{id} is recorded (there is no #{path} in the main " <>
           "copy). Record it first, or hand it in whole."}

      {false, {:ok, _journey}} ->
        {:refused,
         "Refused: journey #{id} is already recorded in the main copy, and its file is " <>
           "not written over. Hand it in by its id alone, and send instructions with " <>
           "tell. Nothing was started."}

      {false, {:none, _path}} ->
        with_stages(work)
    end
  end

  defp by_id(work, _manager), do: work

  defp id_alone?(work),
    do: Map.keys(Map.take(work, @handed_in -- ["skills"])) |> Enum.sort() == ["id", "kind"]

  defp with_stages(%{"stages" => [_ | _]} = work), do: work

  defp with_stages(work),
    do:
      {:refused,
       "Refused: journey #{work["id"]} has no stages; a journey is handed in with its " <>
         "stages. Nothing was started."}

  # An issue handed in is kept in the main copy as issues/<id>.yml (its title,
  # text and criteria), committed as a recorded story is, before its work starts.
  # What it returns is added to what starting the work says.
  # A provision is kept the same way, as provisions/<id>.yml.
  # An issue handed in again with other text than its recorded file is refused, as
  # a journey handed in with fields over its recorded file is: the file is not
  # written over and its work is not started or resumed.
  defp issue_recorded(%{"kind" => kind} = work, %{"repo" => repo})
       when kind in ["issue", "provision"] and is_binary(repo) do
    path = Workflow.StoryFile.issue_path(work)
    kept = Map.take(work, ["id", "kind", "title", "text", "criteria", "target"])
    yaml = Workflow.StoryFile.yaml(kept)

    cond do
      # Not a git checkout: nothing is recorded, and starting the work says so.
      not File.exists?(Path.join(repo, ".git")) ->
        ""

      Checkout.changed?(repo, path) ->
        {:refused,
         "Refused: #{path} has uncommitted changes in the main copy. Nothing was started."}

      kind == "issue" and File.read(Path.join(repo, path)) not in [{:ok, yaml}, {:error, :enoent}] ->
        {:refused,
         "Refused: issue #{work["id"]} is already recorded, and the text handed in differs " <>
           "from the recorded file #{path}, which is not written over (as a journey " <>
           "handed in again with different content is refused). Nothing was started or " <>
           "resumed. Hand it in with the recorded text, or under a new id."}

      true ->
        files = [{path, yaml}]

        case Checkout.commit_files(repo, files, "#{kind} #{work["id"]}: the #{kind} as handed in") do
          {:error, why} -> " (#{path} not recorded: #{inspect(why)})"
          _recorded -> ""
        end
    end
  end

  defp issue_recorded(_work, _manager), do: ""

  # What a work, or a story recorded, is described by.
  defp story_properties do
    %{
      kind: %{type: "string", enum: Run.kinds()},
      id: %{type: "string"},
      text: %{type: "string"},
      criteria: %{type: "array", items: %{type: "string"}},
      stages: %{type: "array", items: %{type: "string"}},
      target: %{type: "string", description: "A provision's target (dev, uat, prod)"},
      title: %{type: "string"},
      workflow: %{type: "string"},
      story: %{type: "string"},
      rules: %{
        type: "array",
        items: %{
          type: "object",
          properties: %{
            rule: %{type: "string"},
            scenarios: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{happy: %{type: "string"}, fails: %{type: "string"}},
                minProperties: 1,
                maxProperties: 1
              }
            }
          },
          required: ["rule", "scenarios"]
        }
      },
      questions: %{type: "array", items: %{type: "string"}}
    }
  end

  defp decide(manager) do
    Alloy.Tool.inline(
      name: "decide",
      description:
        "Decide for a work waiting on its owner's demo: approve, or reject with a note.",
      input_schema: %{
        type: "object",
        properties: %{
          id: %{type: "string"},
          kind: %{type: "string", enum: Run.kinds()},
          demo: %{type: "string", enum: ["approve", "reject"]},
          note: %{type: "string"}
        },
        required: ["id", "kind", "demo"]
      },
      execute: fn %{"id" => id} = input, _context ->
        # Handed in again as it was kept, so its text and criteria go with the decision.
        kept =
          case checkout(manager, id) && Checkout.snapshot(root(manager, id), id) do
            %{} -> Checkout.kept(root(manager, id), id)
            _none -> %{}
          end

        kept
        |> Map.drop(["review", "demo", "note"])
        |> Map.merge(Map.take(input, ["id", "kind", "demo", "note"]))
        |> Map.merge(configured_for(manager))
        |> started()
      end
    )
  end

  defp look(manager) do
    Alloy.Tool.inline(
      name: "look",
      description: "Where a work is, with nothing run: its step, its note, and why it stopped.",
      input_schema: %{
        type: "object",
        properties: %{id: %{type: "string"}, kind: %{type: "string", enum: Run.kinds()}},
        required: ["id", "kind"]
      },
      execute: fn %{"id" => id, "kind" => kind}, _context ->
        case checkout(manager, id) &&
               Run.look(%{"id" => id, "kind" => kind, "root" => root(manager, id)}) do
          %{} = seen -> {:ok, Jason.encode!(seen)}
          _none -> {:ok, absent(manager, kind, id)}
        end
      end
    )
  end

  # A work with no checkout landed, was stopped, or was never started; after a
  # restart a landed one was taken for a stopped one and built again.
  defp absent(manager, kind, id) do
    repo = manager["repo"]
    none = "There is no checkout for #{id}."

    cond do
      is_nil(Checkout.landing(repo)) ->
        none

      Checkout.cancelled?(repo, id) ->
        "#{none} It was stopped for good, and never runs again."

      Checkout.landed?(repo, kind, id) ->
        "#{none} It landed: it is merged in the main copy. Do not hand it in again."

      stopped = Checkout.stopped(repo, id) ->
        "#{none} It stopped at #{stopped["step"]}: #{stopped["reason"]}"

      true ->
        "#{none} It was never started."
    end
  end

  defp root(manager, id), do: Checkout.root(manager["repo"], id)

  # A work's checkout is taken away when it lands, and the manager is told so
  # right after: nothing is run from it then, since spawn prints "Could not cd
  # to" a directory that is not there.
  defp checkout(manager, id), do: File.dir?(root(manager, id))

  defp configured_for(manager) do
    manager
    |> Map.take(["repo", "project", "agents"])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp started(work) do
    case Run.start(work) do
      {:none, _agent} ->
        {:ok, "#{work["id"]}: its repository is not a git checkout."}

      {:cancelled, _agent} ->
        {:ok, "#{work["id"]}: it was stopped for good, and never runs again."}

      {nil, _agent} ->
        {:ok, "#{work["id"]}: done.#{log(work)}"}

      {step, agent} ->
        {:ok,
         "#{work["id"]}: on #{step.name} (#{step.actor}), #{agent || "not started"}.#{log(work)}"}
    end
  end

  # The path of the work's log at the tree it was handed in at, where it has one.
  defp log(work) do
    case Run.log(work) do
      nil -> ""
      path -> " Its log: #{path}"
    end
  end

  # `Alloy.run/2`, or what a test puts in its place.
  defp run(text, opts),
    do: Application.get_env(:workflow, :manager_run, &Alloy.run/2).(text, opts)
end
