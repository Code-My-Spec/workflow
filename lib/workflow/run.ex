defmodule Workflow.Run do
  @moduledoc """
  Takes a piece of work as far as it will go in a checkout: the system's steps
  are run, an agent's step is handed to the agent the template names for it, on
  the provider the caller named, and the work is run again each time one ends.

  A work is `%{"kind" => "issue", "id" => _, "root" => _}`, with the `"text"` of
  what to do, a `"project"` when it is in a directory of the checkout, the
  `"agent"` every agent runs on and `"agents"` for one kind by its step's actor
  (each a `"provider"`, with a `"model"` and a `"key"` where it wants them), and
  a `"review"` ("pass" or "fail" with a `"note"`) or a `"demo"` ("approve" or "reject"
  with a `"note"`) when one is made by hand.
  """

  require Logger

  alias Workflow.Agents
  alias Workflow.Checkout

  @templates %{
    "issue" => Workflow.Issue,
    "story" => Workflow.Story,
    "journey" => Workflow.Journey,
    "provision" => Workflow.Provision
  }

  @doc "The kinds of work there is a template for."
  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@templates)

  # A review, or an owner's decision on a demo, made by hand: the work key it
  # comes in under, the step it is recorded as, and its two answers.
  @decisions [
    {"review", "review", "pass", "fail"},
    {"demo", "approve", "approve", "reject"}
  ]

  # A coder and a reviewer that never agree would hand the work back and forth forever.
  # Thirty, since a story spends two a criterion before its first review: eight ran
  # out on a four-criterion story's first send-back.
  @handoffs 30

  @again "Your last turn ended with the work still on this step and nothing changed."

  @doc "Runs what the system can and answers the step the work is left on, nil when done."
  @spec step(map()) :: Workflow.step() | nil | :none
  def step(work) do
    # A work stopped for good is never run, cut a checkout again, or promoted.
    if cancelled?(work), do: :cancelled, else: with(%{} = work <- owned(work), do: checked(work))
  end

  @doc """
  Stops a work for good: it is marked so (see `Workflow.Checkout.cancel/2`), is
  no longer in flight, and its checkout and branch are taken away. An agent's
  turn running on it is ended first, and waited on, so no turn is left running
  in a checkout that is gone.
  """
  @spec cancel(map()) :: :ok
  def cancel(%{"repo" => repo, "kind" => kind, "id" => id} = work) do
    Checkout.cancel(repo, id)
    end_turns(Checkout.root(repo, id))
    land(work)
    close_browser(id)
    Checkout.remove(repo, kind, id, work["project"])
  end

  # Read from the main copy where there is one: an owned checkout is gone once stopped.
  defp cancelled?(%{"id" => id} = work),
    do: Checkout.cancelled?(work["repo"] || work["root"], id)

  # A work that names a repository but no root of its own gets a worktree checkout
  # cut beside it, reusing one already made for the same id. A work with a root
  # of its own is never the loop's to take away, even if it also names a repo.
  defp owned(%{"root" => _} = work), do: work

  # A copy its project's copy-setup cannot make runnable stops the work, saying why,
  # kept in the repository's git directory since no copy is left.
  defp owned(%{"kind" => kind, "id" => id, "repo" => repo} = work) do
    case Checkout.own(repo, kind, id, work["project"], work["at"]) do
      {:error, reason} ->
        Logger.warning("[Workflow #{id}] copy-setup stopped: #{reason}")
        Checkout.stop(repo, id, "copy-setup", "stopped: #{reason}")
        %{name: "copy-setup", actor: :system, note: reason, stop: true}

      # A kept branch handed in again that does not merge main runs no step.
      {:conflict, reason} ->
        Logger.warning("[Workflow #{id}] merge-main stopped: #{reason}")
        Checkout.stop(repo, id, "merge-main", "stopped: #{reason}")
        %{name: "merge-main", actor: :system, note: reason, stop: true}

      root ->
        work |> Map.put("root", root) |> Map.put("own", true)
    end
  end

  # Seen live: a work stopped mid-turn had its worktree removed under the turn,
  # which then crashed reading it. The turns at work in a checkout are named by it
  # (see `turns/2`): they are killed, and their going down waited on.
  defp end_turns(root) do
    with pid when is_pid(pid) <- :global.whereis_name({__MODULE__, :turns, root}) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      receive do: ({:DOWN, ^ref, :process, _pid, _reason} -> :ok)
    end
  end

  # Taken away, and its branch deleted, once a work the loop made the checkout for is done.
  defp disown(%{"own" => true, "repo" => repo, "kind" => kind, "id" => id} = work),
    do: Checkout.disown(repo, kind, id, work["project"])

  defp disown(_not_owned), do: :ok

  defp checked(work) do
    with %{} <- prepared(work), do: advanced(work)
  end

  # What was handed in is kept, and its decisions recorded, before anything is run.
  defp prepared(%{"id" => id, "root" => root} = work) do
    with %{} = snapshot <- Checkout.snapshot(root, id) do
      story_file(work)
      Checkout.keep(root, id, work)

      Enum.each(@decisions, fn {key, step, pass, fail} ->
        if decision = decision(work, key, pass, fail),
          do: Checkout.record(root, id, step, decision)
      end)

      # Kept apart from the tree, so a merge or failed check first cannot lose it.
      if work["demo"] == "reject", do: Checkout.reject(root, id, work["note"] || "")

      snapshot
    end
  end

  defp advanced(%{"kind" => kind} = work) do
    case advance(@templates[kind], work) do
      nil ->
        disown(work)
        nil

      other ->
        other
    end
  end

  # The system step a work is on at a clean tree, found with nothing run; nil when on none.
  defp system_step(%{"kind" => kind} = work) do
    template = @templates[kind]
    snapshot = snapshot(template, work)

    case Workflow.current(template, snapshot) do
      %{actor: :system} = step when not snapshot.dirty? -> step
      _other -> nil
    end
  end

  # A story or journey is kept in the repository, committed as the work's first
  # commit, so it merges with the code that meets it. An issue gets no file.
  defp story_file(%{"kind" => kind, "id" => id, "root" => root} = work) do
    if path = Workflow.StoryFile.path(work) do
      message = "#{kind} #{id}: the #{kind} as handed in"

      # A story that names a workflow is added to it in the same commit.
      files = [
        {path, Workflow.StoryFile.yaml(work)} | Workflow.StoryFile.workflow_file(work, root)
      ]

      with {:error, why} <- Checkout.commit_files(root, files, message),
           do: Logger.warning("[Workflow #{id}] #{path} not committed: #{inspect(why)}")
    end
  end

  # The checkout's own facts, and whatever more the template reads.
  defp snapshot(template, %{"id" => id, "root" => root} = work) do
    snapshot = Checkout.snapshot(root, id)

    # Loaded first: a module nothing has called yet exports nothing, and the first
    # look at a story ran its tests before anyone had been asked to write one.
    if Code.ensure_loaded?(template) and function_exported?(template, :observe, 2),
      do: Map.merge(snapshot, template.observe(work, snapshot)),
      else: snapshot
  end

  @doc "Where the work is, with nothing run: its step and what was found at its tree."
  @spec look(map()) :: map() | :none
  def look(%{"kind" => kind, "id" => id, "root" => root} = work) do
    with %{} <- Checkout.snapshot(root, id) do
      template = @templates[kind]
      # The checkout's query alone has no criteria or stages: what was kept
      # beside its results fills those in, as they were handed in.
      work = Checkout.kept(root, id) |> Map.merge(work)
      snapshot = snapshot(template, work)
      step = Workflow.current(template, snapshot)

      %{
        id: id,
        kind: kind,
        done: is_nil(step),
        step: step && step.name,
        actor: step && step.actor,
        note: step && step.note,
        head: snapshot.head,
        commits: snapshot.commits,
        found: Map.get(snapshot.results, snapshot.head, %{}),
        steps: steps(template, step),
        working: working?(root),
        log: Checkout.log(root),
        conversation: Workflow.Conversation.path(root, id)
      }
      |> stopped(root, id)
    end
  end

  # Why the loop gave up on the work, said only when it has.
  defp stopped(seen, root, id) do
    case Checkout.stopped(root, id) do
      nil -> seen
      stopped -> Map.put(seen, :stopped, stopped)
    end
  end

  # Whether a process is at work on the checkout now: its lock is held.
  defp working?(root) do
    lock = {{__MODULE__, root}, self()}

    case :global.set_lock(lock, [node()], 0) do
      true -> not :global.del_lock(lock, [node()])
      false -> true
    end
  end

  # Before the current step is done, the current step is current, the rest are waiting.
  defp steps(template, current) do
    index = current && Enum.find_index(template.steps(), &(&1.name == current.name))

    template.steps()
    |> Enum.with_index()
    |> Enum.map(fn {step, i} ->
      state =
        cond do
          is_nil(index) or i < index -> "done"
          i == index -> "current"
          true -> "waiting"
        end

      step |> Map.take([:name, :actor]) |> Map.put(:state, state)
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp decision(work, key, pass, fail) do
    case work[key] do
      ^pass -> %{"status" => pass}
      ^fail -> %{"status" => fail, "note" => work["note"]}
      _not_decided -> nil
    end
  end

  # A system step runs only on a clean tree, and the work is read again after it.
  defp advance(template, %{"id" => id, "root" => root} = work) do
    snapshot = snapshot(template, work)

    case Workflow.current(template, snapshot) do
      %{actor: :system, name: name} when not snapshot.dirty? ->
        Logger.info("[Workflow #{id}] #{name}")
        say(work, "#{name} started")
        result = template.perform(name, work, snapshot)
        Checkout.record(root, id, name, result)
        say(work, "#{name}: #{result["status"]}")

        if name == "promote" and result["status"] == "promoted",
          do: ci(work, snapshot, result["commit"])

        advance(template, work)

      step ->
        step
    end
  end

  # A landing is checked by the project's `just ci` at the landed commit, with the
  # work's checkout and agents kept, idle, until it answers. Green deploys that
  # commit. Red deploys and reverts nothing: a red the previous ci run already had
  # is not reported again, a red new with this landing goes back to the work, and
  # one that cannot (the work is gone, or the red is partly older) is told to the
  # manager. A provision's own fix landing deploys nothing more, so a failing
  # deploy cannot hand itself in again and again.
  defp ci(%{"kind" => "provision"}, _snapshot, _commit), do: :ok

  defp ci(%{"id" => id, "root" => root} = work, %{main_copy: main_copy} = snapshot, commit) do
    say(work, "ci started at #{commit}")

    case Checkout.ci(main_copy, commit, work["project"]) do
      :green ->
        say(work, "ci: passed at #{commit}")
        deploy(work, snapshot, commit)

      :known ->
        say(work, "ci: failed at #{commit}, with the failures the previous ci run had")

      {:new, %{"note" => note}} ->
        say(work, "ci: failed at #{commit}")

        if cancelled?(work) or not File.dir?(root) do
          red(work, commit, note, "The work is gone, so the failure could not go back to it.")
        else
          Checkout.record(root, id, "ci", %{
            "status" => "failed",
            "note" =>
              "`just ci` failed twice at the commit this work landed as on dev (#{commit}), " <>
                "so nothing was deployed. Fix it here, and commit:\n\n" <> note
          })
        end

      {:mixed, %{"note" => note}} ->
        say(work, "ci: failed at #{commit}")

        red(
          work,
          commit,
          note,
          "Some of these failures were already there before this landing, so they belong " <>
            "to no one work and were not sent back to it."
        )
    end
  end

  # Told to the manager once, in plain words, in the background.
  defp red(%{"kind" => kind, "id" => id}, commit, note, why) do
    text =
      "#{kind} #{id} landed on dev as commit #{commit}, and `just ci` failed there twice. " <>
        "Nothing was deployed and nothing was reverted. #{why} The failures:\n\n#{note}"

    if Workflow.Manager.configured(),
      do: Task.start(fn -> Workflow.Messages.say("manager", "workflow", text) end)
  end

  # A green landing hands in a provision for the configured `deploy` target, at
  # the landed commit, in the background.
  defp deploy(work, %{head: head, main_copy: main_copy}, commit) do
    if target = Application.get_env(:workflow, :deploy) do
      provision =
        work
        |> Map.take(["project", "agent", "agents"])
        |> Map.merge(%{
          "kind" => "provision",
          "id" => "#{target}-#{head}",
          "target" => target,
          "at" => commit,
          "repo" => work["repo"] || main_copy
        })

      name = {__MODULE__, :deploy, target}

      # Under the lock the deployer also takes to leave, so no landing is lost as it goes.
      :global.trans({name, self()}, fn ->
        case :global.whereis_name(name) do
          :undefined -> :global.register_name(name, spawn(fn -> deploying(name, provision) end))
          deployer -> send(deployer, {:deploy, provision})
        end
      end)
    end
  end

  # One deploy per target at a time; the landings made while it ran leave only the
  # newest to run after it.
  defp deploying(name, provision) do
    # Its system steps are run here, so the next deploy waits on them.
    start(provision, & &1.())

    next =
      :global.trans({name, self()}, fn ->
        with nil <- newest(nil), do: :global.unregister_name(name) && nil
      end)

    if next, do: deploying(name, next)
  end

  defp newest(latest) do
    receive do
      {:deploy, provision} -> newest(provision)
    after
      0 -> latest
    end
  end

  @doc """
  Runs the work, and when it is left on an agent's step with an agent named for
  it, hands it over in the background. Answers the step and what became of it.
  """
  @spec start(map()) :: {Workflow.step() | nil | :none, String.t() | nil}
  def start(work), do: start(work, &Task.start/1)

  # `run` runs the watched process: in the background, or where the caller waits on it.
  defp start(work, run) do
    if cancelled?(work), do: {:cancelled, nil}, else: start!(work, run)
  end

  # A copy not made yet is made, and its copy-setup run, as the work's first step,
  # in the watched process, never the caller's. Seen live: a 2m10s copy-setup ran
  # inside the manager's hand_in, Alloy's 120s tool timeout killed it, and the work
  # was left a worktree with no works file, never run and never reported. It is
  # kept as in flight before the copy is begun, so one cut short is resumed.
  defp start!(%{"repo" => repo, "id" => id} = work, run) when not is_map_key(work, "root") do
    if File.dir?(Checkout.root(repo, id)) do
      copied(work, run)
    else
      fly(work)
      run.(fn -> copied(work, &apply(&1, [])) end)
      {%{name: "copy-setup", actor: :system, note: "making the work's copy"}, "started"}
    end
  end

  defp start!(work, run), do: owned!(work, run)

  # Resolved once, so an agent's step and the turns after it run in the same checkout.
  # A copy-setup that fails is landed and said as any step's stop is; nothing is left
  # in flight that nobody runs.
  defp copied(work, run) do
    case owned(work) do
      %{stop: true, name: name, note: note} = step ->
        land(work, "stopped at #{name}: stopped: #{note}")
        {step, "stopped: #{note}"}

      owned ->
        case owned!(owned, run) do
          {_step, "started"} = started ->
            started

          # Left with nobody to run it, as a hand-in made before the copy was: not in flight.
          left ->
            land(work)
            left
        end
    end
  end

  defp owned!(work, run) do
    # Handed in again: what the checks found at this tree before is not reused.
    Checkout.afresh(work["root"], work["id"])

    # A system step is run in the watched process, not the caller's: a caller
    # killed or timed out mid-step took `just` down with it, and nothing was said.
    with %{} <- prepared(work),
         _said <- say(work, "handed in"),
         %{} = step <- system_step(work) do
      run.(fn -> watch(step, work) end)
      {step, "started"}
    else
      :none -> {:none, nil}
      nil -> started(advanced(work), work)
    end
  end

  defp started(step, work) do
    case step do
      # A step the template says nobody can act on: the work is stopped, saying why.
      %{stop: true, note: note} = step ->
        stop(work, step, "stopped: #{note}")
        {step, "stopped: #{note}"}

      %{agent: _} = step ->
        case Agents.provider(step, work) do
          {:ok, _provider} ->
            Task.start(fn -> watch(step, work) end)
            {step, "started"}

          :none ->
            {step, nil}

          # An agent named that cannot run would leave the work sitting: it is stopped.
          {:error, reason} ->
            stop(work, step, "not started: #{reason}")
            {step, "not started: #{reason}"}
        end

      # A system step is left only by a dirty tree. With no agent at work in the
      # checkout nobody will commit it and the work would sit: it is stopped.
      # Seen live: a service restarted under an agent mid-edit dropped the work.
      %{actor: :system} = step ->
        reason = dirty(work["root"])
        lock = {{__MODULE__, work["root"]}, self()}

        case :global.trans(lock, fn -> stop(work, step, reason) end, [node()], 0) do
          :aborted -> {step, nil}
          _stopped -> {step, reason}
        end

      other ->
        {other, nil}
    end
  end

  # The turns run in a process of their own, monitored: one that goes down is
  # stopped, never lost. Its lock on the checkout goes with it, since
  # `:global.trans` releases a lock when its holder dies.
  defp watch(step, work) do
    {_pid, ref} = spawn_monitor(fn -> turns(step, work) end)

    receive do
      {:DOWN, ^ref, :process, _pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, _pid, reason} ->
        stop(work, step, "its turns went down: #{Exception.format_exit(reason)}")
    end
  end

  defp turns(step, %{"root" => root} = work) do
    # One agent at a time in a checkout; a second call while it works starts none.
    # The lock is the checkout; the id's second part is who asks for it. The work
    # is kept as in flight only once the lock is held, so one that starts none
    # leaves nothing behind for a restart.
    with :aborted <-
           :global.trans(
             {{__MODULE__, root}, self()},
             fn ->
               # Named by the checkout, so a stop can end it (see `end_turns/1`).
               :global.re_register_name({__MODULE__, :turns, root}, self())
               fly(work)

               if step.actor == :system,
                 do: system(work),
                 else: turn(step, work, @handoffs)
             end,
             [node()],
             0
           ),
         do:
           Logger.info(
             "[Workflow #{work["id"]}] #{step.name} not started: an agent is already at work in #{root}"
           )
  end

  # The system's steps, run under the checkout's lock with the work in flight,
  # and what they leave it on taken as `start/1` would have.
  defp system(%{"id" => id, "root" => root} = work) do
    case step(work) do
      %{stop: true, note: note} = step ->
        stop(work, step, "stopped: #{note}")

      %{agent: _} = step ->
        case Agents.provider(step, work) do
          {:ok, _provider} -> turn(step, work, @handoffs)
          :none -> land(work, landed(step))
          {:error, reason} -> stop(work, step, "not started: #{reason}")
        end

      %{actor: :system} = step ->
        stop(work, step, dirty(root))

      left ->
        land(work, landed(left))
        Logger.info("[Workflow #{id}] left on #{(is_map(left) && left.name) || "done"}")
    end
  end

  # What git says is uncommitted, not a guess at why: seen live, a tree dirty only
  # with untracked leftovers that main ignores was stopped as "uncommitted changes".
  defp dirty(root) do
    "stopped: uncommitted changes in #{root} and no agent at work on them. " <>
      "`git status --short` says:\n\n#{Checkout.status(root)}"
  end

  # Nothing the system does runs on a dirty tree, so work left uncommitted would
  # leave the work where it is: the agent that left it is told to commit it.
  # Seen live: QA force-added a scratch file under an ignored folder, the next
  # test run rewrote it, and the work stopped dirty. Such paths leave the branch.
  defp uncommitted(step, root, id) do
    if Checkout.snapshot(root, id).dirty? do
      note =
        case Checkout.ignored_changes(root) do
          [] ->
            "You left changes uncommitted. Commit them with git, then end your turn."

          paths ->
            "These changed paths are committed but named in .gitignore: " <>
              Enum.join(paths, ", ") <>
              ". Take them out of the branch with `git rm --cached <path>`, commit that " <>
              "with git, then end your turn."
        end

      if step.note != note, do: %{step | note: note}
    end
  end

  defp turn(step, %{"id" => id, "root" => root} = work, handoffs, sent \\ nil) do
    # The branch's commits before the agent's turn, to tell whether it made one.
    {from, tree} =
      case Checkout.snapshot(root, id) do
        %{commits: commits, head: head} -> {commits, head}
        _no_git -> {nil, nil}
      end

    # Seen live: QA sent back to the same step five times in forty seconds, the
    # tree unchanged. A third send of the same step at the same tree waits instead.
    seen =
      {step.actor, step.name, tree,
       step.note && String.replace_prefix(step.note, "#{@again}\n\n", "")}

    times =
      case sent do
        {^seen, times} -> times + 1
        _other -> 1
      end

    if times < 3, do: say(work, "#{step.name} started (#{step.actor})")

    case times < 3 && agent_turn(step, work) do
      false ->
        wait(work, step, "sent to the #{step.actor} a third time with the same tree and note")

      {:error, error} ->
        stop(work, step, "parked: its run ended in error twice: #{inspect(error)}")

      decided ->
        turned(step, work, handoffs, decided, from, {seen, times})
    end
  end

  # A work stopped for good while its agent's turn ran: nothing more is done in it.
  defp turned(step, work, handoffs, decided, from, sent) do
    if cancelled?(work),
      do: land(work, landed(:cancelled)),
      else: turned!(step, work, handoffs, decided, from, sent)
  end

  defp turned!(step, %{"id" => id, "root" => root} = work, handoffs, decided, from, sent) do
    # What an agent decided is its step's result, at the tree it decided it at.
    if decided != %{}, do: Checkout.record(root, id, step.name, decided)
    # A coder's turn on `work` was given any rejection note still owed: it is answered.
    if step.name == "work", do: Checkout.answered(root, id)
    # Whose commit the tree is, and the commits before the turn that made it, for a
    # template that reads a result by who made it.
    Checkout.record(root, id, "by", %{"step" => step.name, "at" => now(), "from" => from})
    said = Enum.reject([decided["status"], decided["note"]], &is_nil/1)
    say(work, "#{step.name} turn by the #{step.actor} ended: #{Enum.join(said, ": ")}")
    work = Map.drop(work, ["review", "demo", "note"])

    case uncommitted(step, root, id) || step(work) do
      # An agent's step again: an agent that moved nothing is told so, not left
      # sitting on it; the handoffs bound how often.
      %{agent: _} = next when handoffs > 0 ->
        turn(again(next, step), work, handoffs - 1, sent)

      %{agent: _} = left ->
        stop(work, left, "stopped: its #{@handoffs} handoffs are spent")

      left ->
        land(work, landed(left))
        if is_nil(left), do: Agents.forget(id)
        Logger.info("[Workflow #{id}] left on #{(is_map(left) && left.name) || "done"}")
    end
  end

  # Giving up is kept with the work's results and said once, never left silent.
  defp stop(work, step, reason) do
    if cancelled?(work), do: land(work), else: stop!(work, step, reason)
  end

  defp stop!(%{"id" => id, "root" => root} = work, step, reason) do
    Logger.warning("[Workflow #{id}] #{step.name} #{reason}")
    Checkout.stop(root, id, step.name, reason)
    land(work, "stopped at #{step.name}: #{reason}")
  end

  # Kept where a stop is, so the manager's look says why, and said as a work
  # waiting on its owner says it.
  defp wait(%{"id" => id, "root" => root} = work, step, why) do
    reason = "waiting on its owner: #{why}"
    Logger.warning("[Workflow #{id}] #{step.name} #{reason}")
    Checkout.stop(root, id, step.name, reason)
    land(work, landed(%{step | note: why}))
  end

  defp landed(nil), do: "done"
  defp landed(:cancelled), do: "stopped for good by the manager"
  defp landed(%{name: name, note: note}), do: "waiting on its owner at #{name}: #{note}"
  defp landed(left), do: "left on #{inspect(left)}"

  @doc """
  Starts again every work that was in flight when the service went down. One
  whose agent can no longer be run, its key being kept nowhere, is stopped by
  `start/1` with that as its reason.
  """
  @spec resume() :: :ok
  def resume do
    for file <- Path.wildcard(Path.join(works_dir(), "*.json")),
        {:ok, %{} = work} <- [file |> File.read!() |> Jason.decode()] do
      # Done, the owner's, or not runnable: no longer in flight.
      with {_step, agent} when agent != "started" <- start(work), do: land(work)
    end

    :ok
  end

  @doc "Why the loop gave up on the work, or `nil` while it has not."
  @spec stopped(map()) :: map() | nil
  # Read from the repository where the loop owns the copy: it shares the copy's
  # git directory, and is there when a copy-setup that failed left no copy.
  def stopped(%{"id" => id} = work), do: Checkout.stopped(work["root"] || work["repo"], id)

  # A work in flight is kept on disk by its id, so a restart can resume it; a
  # key is kept nowhere, so it is taken out of what each agent runs on.
  defp fly(%{"id" => id} = work) do
    keyless =
      work
      |> Map.replace_lazy("agent", &keyless/1)
      |> Map.replace_lazy(
        "agents",
        &Map.new(&1, fn {actor, agent} -> {actor, keyless(agent)} end)
      )

    File.mkdir_p!(works_dir())
    File.write!(Path.join(works_dir(), "#{id}.json"), Jason.encode!(keyless))
  end

  defp keyless(%{} = agent), do: Map.delete(agent, "key")
  defp keyless(agent), do: agent

  # The work's agent-browser session (see Agents.run) goes with it; a machine
  # without agent-browser has none to close.
  defp close_browser(id) do
    Application.get_env(:workflow, :cmd, &System.cmd/3).(
      "agent-browser",
      ["--session", id, "close"],
      stderr_to_stdout: true
    )
  rescue
    ErlangError -> :ok
  end

  # Done, waiting on its owner, or stopped: nothing left to resume.
  defp land(%{"id" => id}), do: File.rm(Path.join(works_dir(), "#{id}.json"))

  # Landed by the loop, which tells the manager how, in the background so the
  # loop never waits on it.
  defp land(%{"id" => id, "kind" => kind} = work, how) do
    say(work, how)
    land(work)
    close_browser(id)

    if Workflow.Manager.configured(),
      do:
        Task.start(fn ->
          Workflow.Messages.say(
            "manager",
            "workflow",
            "#{kind} #{id}: #{how}#{outcome(work, how)}"
          )
        end)
  end

  # A work done says what it left, so the manager can tell an empty one from a real one.
  defp outcome(%{"id" => id} = work, "done") do
    %{note: note, landed: landed} = Checkout.outcome(work["repo"] || work["root"], id)

    landed =
      case landed do
        nil -> "Nothing landed."
        {commit, nil} -> "Landed as commit #{commit}."
        {commit, stat} -> "Landed as commit #{commit}: #{stat}."
      end

    "\n\n" <> landed <> "\nLast decision note: " <> (note || "none")
  end

  defp outcome(_work, _how), do: ""

  @doc """
  The path of the work's log at the tree its checkout is at now, nil where it
  has none: what a hand-in answers. See `Workflow.Checkout.log/1`.
  """
  @spec log(map()) :: String.t() | nil
  def log(%{"root" => root}), do: Checkout.log(root)
  # A copy not made yet is cut at the repository's tree: its log is there.
  def log(%{"repo" => repo, "id" => id}),
    do: Checkout.log(Checkout.root(repo, id)) || Checkout.log(repo)

  # One line appended to the log of the tree the work is at. A tree moved since
  # this process last wrote (an agent committed) has the old log's last line name
  # the new tree, so a reader can follow. A checkout taken away once done leaves
  # its last line in the log last written.
  defp say(%{"root" => root}, line) do
    last = Process.get({__MODULE__, :log, root})
    path = Checkout.log(root) || last

    if last && path != last do
      tree = path |> Path.dirname() |> Path.basename()
      Checkout.log(last, "the tree moved to #{tree}: the log goes on in #{path}")
    end

    if path do
      Process.put({__MODULE__, :log, root}, path)
      Checkout.log(path, line)
    end
  end

  # A work whose copy could not be made has no log to say it in.
  defp say(_no_copy, _line), do: nil

  @doc "Where works in flight are kept, one file each."
  @spec works_dir() :: String.t()
  def works_dir,
    do:
      Application.get_env(:workflow, :works_dir) ||
        Path.join([System.user_home!(), ".workflow", "works"])

  # The same step with the same note, as it was or as already told again, is nothing moved.
  defp again(%{name: name, note: note} = next, %{name: name, note: said}) do
    told = "#{@again}\n\n#{note}"
    if said in [note, told], do: %{next | note: told}, else: next
  end

  defp again(next, _step), do: next

  # The provider can end a turn in error (seen live: "Claude Code returned
  # tool_calls for an end_turn response"); told again once before the work is
  # stopped, since handing the same request in again is the only other way through.
  defp agent_turn(step, work) do
    case agents_run(step, work) do
      {decided, nil} ->
        decided

      {_decided, _error} ->
        case agents_run(step, work) do
          {decided, nil} -> decided
          {_decided, error} -> {:error, error}
        end
    end
  end

  # `Agents.run/2`, or what a test puts in its place.
  defp agents_run(step, work),
    do: Application.get_env(:workflow, :agents_run, &Agents.run/2).(step, work)
end
