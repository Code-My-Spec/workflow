defmodule Workflow.Manager do
  @moduledoc """
  The project manager: the one agent that outlives a work. It is told things,
  one message at a time, and can do six: hand a work in, decide for a work's owner, look at a work, tell a running work something,
  stop a work for good, and message the person's chat (`message_chat`, over `Workflow.Server`). It does not code, review, test or read the
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

  # When the manager messages the person's chat, in its brief and its tool's description.
  @message_chat_brief "Use message_chat to reach the person's chat when the person must know " <>
                        "or decide something now: a question only they can answer, a stopped " <>
                        "work, a red that needs them. It is not for routine progress, which " <>
                        "the chat collects with say."

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

  A story already in the repository (`.code_my_spec/stories/<id>.yml`, or `stories/<id>.yml` \
  in an older project) is handed in by its id alone, with `at` the commit sha you are told \
  ("hand in story <id> at <sha>"); with no sha, it is read at the main copy's HEAD. A story \
  whose file at that commit has open questions is refused: add `go: true` only when the \
  person explicitly said go despite them. Handing a story in again at a newer sha while it \
  is in flight queues a work for the difference; the same sha again is refused.

  Hand in only what the person asks to have built.

  When a work is done, say so in one line. When a work waits on its owner, do not decide for \
  the owner unless the owner has told you how; say what is waiting. When a work is stopped, look \
  at it once and say plainly why it stopped and that it needs a person. Hand a stopped work in \
  again only when you are told to.

  Nobody waits on your answer to a message from the loop: the owner reads it later, so say \
  what you did or exactly what a person must do.

  #{@message_chat_brief}

  A push the box refuses or fails is a failure of this app, and yours to act on at once: hand \
  in an issue with the failure's text, without asking anyone. The loop is not a person and will \
  not say go ahead. Ask only about what a person must decide.

  A failure of the loop itself (a step sent back three times with the same tree and note) is not a fault in this app, and no \
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
      messages = bounded(remembered())
      conversation = Workflow.Conversation.path(manager["repo"], "manager")
      who = %{work: nil, step: nil, role: :manager}
      # Its own tools, and the plugin's MCP servers' beside them.
      tools = tools(manager) ++ Workflow.Mcp.tools(:manager)
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

  defp remember(messages), do: File.write!(file(), :erlang.term_to_binary(messages))

  # What of the kept conversation fits the context, in bytes of its messages as
  # kept: about 100k tokens at four bytes a token, under every model's context.
  @bound 400_000

  @doc "How large, in bytes as kept, the conversation a manager's turn starts from may be."
  @spec bound() :: pos_integer()
  def bound, do: @bound

  # The kept conversation's newest turns that fit the bound: its oldest are
  # dropped a whole turn at a time (up to the next prompt the manager was told),
  # so no tool result is left without its call. One turn too large alone leaves none.
  defp bounded(messages) do
    if byte_size(:erlang.term_to_binary(messages)) <= @bound,
      do: messages,
      else: messages |> tl() |> Enum.drop_while(&(not prompt?(&1))) |> bounded()
  end

  defp prompt?(%{role: :user, content: "" <> _text}), do: true
  defp prompt?(_message), do: false

  @doc """
  The manager's own tools (hand_in, decide, look, tell, stop, message_chat) for the given
  manager settings: what its turns run with, and what POST /mcp/manager offers.
  """
  @spec tools(map()) :: [Alloy.Tool.Inline.t()]
  def tools(manager),
    do:
      Enum.map(
        [
          hand_in(manager),
          decide(manager),
          look(manager),
          told(manager),
          stop(manager),
          message_chat()
        ],
        &plain_id/1
      )

  # A tool given an id that is not a plain name refuses it before anything is done.
  defp plain_id(tool) do
    %{
      tool
      | execute: fn input, context ->
          case is_map_key(input, "id") && Checkout.refused(input["id"]) do
            "" <> why -> {:ok, why}
            _plain -> tool.execute.(input, context)
          end
        end
    }
  end

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
              else: Workflow.StoryFile.path(Map.put(work, "text", ""), repo)

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

  # Sends the person's chat a message over the server line (`Workflow.Server`):
  # `message` {text} pushed on `loop:<project>`, answered ok {id}.
  defp message_chat do
    Alloy.Tool.inline(
      name: "message_chat",
      description:
        "Send a message to the person's chat inbox, unprompted. " <> @message_chat_brief,
      input_schema: %{
        type: "object",
        properties: %{text: %{type: "string"}},
        required: ["text"]
      },
      execute: fn input, _context -> {:ok, chat_sent(input["text"])} end
    )
  end

  defp chat_sent("" <> text) do
    case Workflow.Server.call("message", %{"text" => text}) do
      {:ok, %{"id" => id}} ->
        "Delivered to the person's chat, as message #{id}."

      {:error, :no_server} ->
        "Not delivered: there is no server configured, so nothing was sent."

      {:error, {:no_reply, why}} ->
        "Not delivered: the server sent no reply (#{inspect(why)})."

      {:error, why} ->
        "Not delivered: the server refused it: #{inspect(why)}"

      other ->
        "Not delivered: the server's reply gave no id: #{inspect(other)}"
    end
  end

  defp chat_sent(_none), do: "Not delivered: there was no text, so nothing was sent."

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

  # What a work is handed in with: the old text and criteria (a journey's stages),
  # or a story's own shape.
  @handed_in ~w(kind id text criteria stages title workflow story_id story rules questions skills action environment)

  defp hand_in(manager) do
    Alloy.Tool.inline(
      name: "hand_in",
      description:
        "Hand a work in: an issue (with text) for a fault, a story for something new (with " <>
          "title, workflow, story, rules with their scenarios, and questions), a journey " <>
          "(with stages), or a devops work (with action and environment) that runs the " <>
          "project's devops.yml through the DevOps plugin's scripts. A story already in the " <>
          "repository is handed in by its id alone, with `at` the commit to read it at.",
      input_schema: %{
        type: "object",
        properties:
          Map.merge(story_properties(), %{
            skills: %{
              type: "object",
              description:
                "More skill folders for this work only, by role (coder, reviewer, ...): " <>
                  "each a folder holding a SKILL.md, or a folder of such folders",
              additionalProperties: %{type: "array", items: %{type: "string"}}
            },
            at: %{
              type: "string",
              description:
                "A story handed in by its id alone: the commit sha its file is read at " <>
                  "(default: the main copy's HEAD)"
            },
            go: %{
              type: "boolean",
              description:
                "A story handed in by its id alone: true when the person said go despite " <>
                  "its open questions"
            }
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

            case by_id(work, manager, Map.take(input, ["at", "go"])) do
              {:refused, said} ->
                {:ok, said}

              {:queued, work} ->
                Run.queue(work)

                {:ok,
                 "#{work["id"]}: story #{work["story_of"]} at #{work["story_at"]}, queued " <>
                   "behind #{work["behind"]}: it starts once #{work["behind"]} is done or " <>
                   "stopped, and builds the difference from #{work["story_from"]}."}

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

  # A story handed in by its id alone is built from its file as it is at a commit
  # of the main copy (fetched first): `at`, else the main copy's HEAD. That sha is
  # recorded on the work (`story_at`), and nothing of it is written or committed.
  # One that carries its text gets the ids it lacks before it is recorded.
  defp by_id(%{"kind" => "story"} = work, manager, pin) do
    cond do
      id_alone?(work) -> pinned(work, manager, pin)
      shaped?(work) -> work |> Workflow.StoryFile.with_ids() |> ids_checked() |> with_criteria()
      true -> with_criteria(work)
    end
  end

  # A journey too, its stages included; its recorded file is not written over by
  # one handed in with fields, and one handed in whole needs stages.
  defp by_id(%{"kind" => "journey", "id" => id} = work, manager, _pin) do
    recorded =
      if is_binary(manager["repo"]),
        do: Workflow.StoryFile.recorded(work, manager["repo"]),
        else: {:none, Workflow.StoryFile.located(work, nil)}

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

  # A devops work names its action and environment, and its project's devops.yml
  # resolves to the plugin's scripts, every line, before anything runs.
  defp by_id(%{"kind" => "devops", "id" => id} = work, manager, _pin) do
    dir = Path.join(manager["repo"] || ".", manager["project"] || ".")

    cond do
      work["action"] not in ["check", "apply"] ->
        {:refused,
         "Refused: devops work #{id} needs an action, check or apply. Nothing was started."}

      not is_binary(work["environment"]) or work["environment"] == "" ->
        {:refused,
         "Refused: devops work #{id} needs an environment (uat, ...). Nothing was started."}

      true ->
        case Workflow.Devops.resolve(dir, work["environment"]) do
          {:ok, _steps} -> work
          {:refused, why} -> {:refused, "Refused: #{why}. Nothing was started."}
        end
    end
  end

  defp by_id(work, _manager, _pin), do: work

  defp pinned(%{"id" => id} = work, manager, pin) do
    repo = manager["repo"]

    with :ok <- sha_shaped(pin["at"]),
         {:ok, sha} <- commit(repo, pin["at"]),
         {:ok, story, path} <- story_at(work, repo, sha),
         %{} <- ids_checked(Map.put(story, "id", id)),
         :ok <- no_questions(story, id, sha, pin["go"]),
         %{} = work <-
           story
           |> Map.put("criteria", Workflow.StoryFile.criteria(story))
           |> Map.merge(work)
           |> Map.merge(%{"recorded" => true, "story_at" => sha, "story_path" => path})
           |> with_criteria() do
      behind(work, repo)
    end
  end

  defp sha_shaped(nil), do: :ok

  defp sha_shaped(at) do
    if is_binary(at) and at =~ ~r/\A[0-9a-fA-F]{4,40}\z/,
      do: :ok,
      else: {:refused, "Refused: at #{inspect(at)} is not a commit sha. Nothing was started."}
  end

  defp commit(repo, at) do
    case Checkout.pinned(repo, at) do
      {:ok, sha} ->
        {:ok, sha}

      :none when is_binary(at) ->
        {:refused,
         "Refused: there is no commit #{at} in the main copy, fetched just now. " <>
           "Nothing was started."}

      :none ->
        {:refused,
         "Refused: #{inspect(repo)} has no commit at its HEAD, so no story is recorded " <>
           "there. Nothing was started."}
    end
  end

  defp story_at(%{"id" => id} = work, repo, sha) do
    case Workflow.StoryFile.at(work, repo, sha) do
      {:ok, story, path} ->
        {:ok, story, path}

      {:none, paths} ->
        {:refused,
         "Refused: no story #{id} is recorded at commit #{sha}: neither " <>
           Enum.join(paths, " nor ") <>
           " is in the main copy at that commit. Commit it first, or hand it in whole. " <>
           "Nothing was started."}
    end
  end

  defp no_questions(story, id, sha, go) do
    case story["questions"] |> List.wrap() |> Enum.reject(&(&1 in [nil, ""])) do
      open when open == [] or go == true ->
        :ok

      open ->
        {:refused,
         "Refused: story #{id} at #{sha} has open questions: " <>
           Enum.join(open, "; ") <>
           ". Settle them in the story file, or hand it in with go: true when the person " <>
           "said to go ahead despite them. Nothing was started."}
    end
  end

  # A story in flight already, or queued, at that sha is a duplicate. At a newer
  # sha it is a new work, `<story>-<short sha>`, queued behind the story's last
  # work and told the difference from that work's sha. With none in flight it is
  # started as before.
  defp behind(%{"id" => id, "story_at" => sha} = work, repo) do
    works = Enum.filter(Run.story_works(), &((&1["story_of"] || &1["id"]) == id))
    ahead = Enum.map(works, & &1["behind"])

    cond do
      same = Enum.find(works, &(&1["story_at"] == sha)) ->
        {:refused,
         "Refused: story #{id} at #{sha} is already handed in, as #{same["id"]}: a " <>
           "duplicate. Nothing was started."}

      works == [] ->
        work

      true ->
        last = Enum.find(works, List.last(works), &(&1["id"] not in ahead))
        from = last["story_at"]

        if is_binary(from) and not Checkout.before?(repo, from, sha) do
          {:refused,
           "Refused: story #{id} is in flight at #{from}, and #{sha} is not newer. " <>
             "Nothing was started."}
        else
          {:queued,
           Map.merge(work, %{
             "id" => "#{id}-#{String.slice(sha, 0, 7)}",
             "story_of" => id,
             "behind" => last["id"],
             "story_from" => from,
             "story_diff" => from && Checkout.diff(repo, from, sha, work["story_path"])
           })}
        end
    end
  end

  # A story in the story's shape (title, story, rules) has an id for itself, each
  # rule and each scenario, none repeated; one handed in the old way (text and
  # criteria) has no such parts.
  defp ids_checked(work) do
    case shaped?(work) && Workflow.StoryFile.ids_refused(work) do
      "" <> refused -> {:refused, refused}
      _ok -> work
    end
  end

  defp shaped?(work), do: Enum.any?(["title", "story", "rules"], &Map.has_key?(work, &1))

  defp id_alone?(work),
    do: Map.keys(Map.take(work, @handed_in -- ["skills"])) |> Enum.sort() == ["id", "kind"]

  defp with_stages(%{"stages" => [_ | _]} = work), do: work

  defp with_stages(work),
    do:
      {:refused,
       "Refused: journey #{work["id"]} has no stages; a journey is handed in with its " <>
         "stages. Nothing was started."}

  # A story is walked one criterion at a time (see `Workflow.Parts`): one with none,
  # carried or read from its file, is refused, as a journey with no stages is.
  defp with_criteria(%{} = work) do
    case Workflow.StoryFile.criteria(work) do
      [_ | _] ->
        work

      _none ->
        {:refused,
         "Refused: story #{work["id"]} has no criteria; a story is handed in with its " <>
           "criteria (rules with their scenarios). Nothing was started."}
    end
  end

  defp with_criteria(refused), do: refused

  # An issue handed in is kept in the main copy as issues/<id>.yml (its title,
  # text and criteria), committed as a recorded story is, before its work starts.
  # What it returns is added to what starting the work says.
  # An issue handed in again with other text than its recorded file is refused, as
  # a journey handed in with fields over its recorded file is: the file is not
  # written over and its work is not started or resumed.
  defp issue_recorded(%{"kind" => "issue" = kind} = work, %{"repo" => repo})
       when is_binary(repo) do
    path = Workflow.StoryFile.issue_path(work)
    kept = Map.take(work, ["id", "kind", "title", "text", "criteria"])
    yaml = Workflow.StoryFile.yaml(kept)

    cond do
      # Not a git checkout: nothing is recorded, and starting the work says so.
      not File.exists?(Path.join(repo, ".git")) ->
        ""

      Checkout.changed?(repo, path) ->
        {:refused,
         "Refused: #{path} has uncommitted changes in the main copy. Nothing was started."}

      File.read(Path.join(repo, path)) not in [{:ok, yaml}, {:error, :enoent}] ->
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

  # What a work is described by.
  defp story_properties do
    %{
      kind: %{type: "string", enum: Run.kinds()},
      id: %{type: "string"},
      text: %{type: "string"},
      criteria: %{type: "array", items: %{type: "string"}},
      stages: %{type: "array", items: %{type: "string"}},
      title: %{type: "string"},
      workflow: %{type: "string"},
      story_id: %{type: "string", description: "The story's own id; generated when absent"},
      story: %{type: "string"},
      rules: %{
        type: "array",
        items: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "The rule's id; generated when absent"},
            rule: %{type: "string"},
            scenarios: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  id: %{type: "string", description: "The scenario's id; generated when absent"},
                  happy: %{type: "string"},
                  fails: %{type: "string"}
                },
                minProperties: 1,
                maxProperties: 2
              }
            }
          },
          required: ["rule", "scenarios"]
        }
      },
      questions: %{type: "array", items: %{type: "string"}},
      action: %{
        type: "string",
        enum: ["check", "apply"],
        description: "A devops work: check runs every probe, apply each apply then its probe"
      },
      environment: %{
        type: "string",
        description: "A devops work: the environment whose devops.yml lines it runs (uat, ...)"
      }
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
        # An id with no checkout has no work waiting on its demo: refused, not started.
        case checkout(manager, id) && Checkout.snapshot(root(manager, id), id) do
          %{} ->
            Checkout.kept(root(manager, id), id)
            |> Map.drop(["review", "demo", "note"])
            |> Map.merge(Map.take(input, ["id", "kind", "demo", "note"]))
            |> Map.merge(configured_for(manager))
            |> started()

          _none ->
            {:ok,
             "Refused: there is no work #{id} waiting on its owner's demo. " <>
               "Nothing was started, recorded or resumed."}
        end
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
