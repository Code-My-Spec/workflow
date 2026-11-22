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
    "journey" => Workflow.Journey
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

      # The owner's decision is an event, recorded as one pushed or posted is.
      Enum.each(@decisions, fn {key, step, pass, fail} ->
        if decision = decision(work, key, pass, fail),
          do:
            if(step == "approve",
              do: record_event(root, id, step, decision),
              else: Checkout.record(root, id, step, decision)
            )
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

      with {:error, why} <-
             Checkout.commit_files(root, [{path, Workflow.StoryFile.yaml(work)}], message),
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
        advance(template, work)

      step ->
        step
    end
  end

  @doc """
  Records the event `name`, with its `payload`, for the work `id`, at its tree
  as any step's result is, and runs the work on from there in the background:
  an external step (`actor: :external`) is done once its event is recorded. The
  one way in for an event pushed on the server's channel or POSTed to
  `/works/:id/events`. A `ci` event whose verdict is flaky also hands in an
  issue for each flaky test. Answers `:ok`, or `:none` with no copy for `id`.
  """
  @spec event(String.t(), String.t(), term()) :: :ok | :none
  def event(id, name, payload) do
    case waiting(id) do
      nil ->
        :none

      work ->
        payload = if is_map(payload), do: payload, else: %{}
        record_event(work["root"], id, name, payload)
        if name == "ci" and payload["verdict"] == "flaky", do: flaky(work, payload)
        Task.start(fn -> watch(%{name: name, actor: :system, note: nil}, work) end)
        :ok
    end
  end

  defp record_event(root, id, name, payload),
    do: Checkout.record(root, id, name, Map.put(payload, "event", name))

  # A work waiting holds only its record: it is read back from its copy, in
  # flight or cut from the manager's repo, with the manager's agents.
  defp waiting(id) do
    manager = Workflow.Manager.configured() || %{}

    flying =
      with {:ok, json} <- File.read(Path.join(works_dir(), "#{id}.json")),
           {:ok, %{} = work} <- Jason.decode(json) do
        work
      else
        _none -> %{}
      end

    # In flight it is whole; else it was the manager's, cut beside the manager's repo.
    flying =
      if flying == %{} and manager["repo"],
        do: Map.take(manager, ["repo", "project", "agents"]),
        else: flying

    with nil <- Checkout.refused(id),
         "" <> root <- flying["root"] || (flying["repo"] && Checkout.root(flying["repo"], id)),
         true <- File.dir?(root) do
      flying
      |> Map.merge(Map.drop(Checkout.kept(root, id), ["review", "demo", "note"]))
      |> Map.merge(%{"id" => id, "root" => root})
    else
      _none -> nil
    end
  end

  # One issue handed in per flaky test, named by the test and the tree.
  defp flaky(work, payload) do
    tree = to_string(payload["tree"])

    for test <- List.wrap(payload["flaky"]), repo = work["repo"] || work["root"] do
      %{
        "kind" => "issue",
        "id" => "flaky-#{short(test)}-#{String.slice(tree, 0, 7)}",
        "text" =>
          "The test #{test} is flaky: on the tree #{tree} it failed and passed. " <>
            "Make it pass every time.",
        "repo" => repo
      }
      |> Map.merge(Map.take(work, ["project", "agents", "agent"]))
      |> start()
    end
  end

  # A test's name, short and plain enough for an id: its file's name where it has one.
  defp short(test) do
    test
    |> to_string()
    |> Path.basename()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> String.trim("-")
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
    # A copy whose copy-setup never passed is half-made: it is made again, here too.
    if File.dir?(Checkout.root(repo, id)) and not Checkout.copying?(repo, id) do
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
    # Whose turn it was when the service went down, kept in flight by `turn/5`.
    {turn, work} = Map.pop(work, "turn")
    # Handed in again: what the checks found at this tree before is not reused.
    Checkout.afresh(work["root"], work["id"])

    # A system step is run in the watched process, not the caller's: a caller
    # killed or timed out mid-step took `just` down with it, and nothing was said.
    with %{} <- prepared(work),
         _said <- say(work, "handed in"),
         nil <- kept_turn(turn, work),
         %{} = step <- system_step(work) do
      run.(fn -> watch(step, work) end)
      {step, "started"}
    else
      :none -> {:none, nil}
      nil -> started(advanced(work), work)
      %{agent: _} = turn -> started(turn, work)
    end
  end

  # Seen live: a service stopped while the coder answered a failed review came
  # back on certify, and stopped there dirty. A start runs certify afresh at the
  # tree, and certify comes before the review that failed there, so the work read
  # as on certify, and nothing kept said whose turn it was. The agent whose turn
  # it was is given it back, with the note it was given.
  defp kept_turn(%{"step" => name} = turn, %{"kind" => kind}) do
    if step = Enum.find(@templates[kind].steps(), &(&1.name == name and is_map_key(&1, :agent))),
      do: agent_step(step, turn["note"])
  end

  defp kept_turn(_none, _work), do: nil

  defp agent_step(definition, note),
    do: definition |> Map.take([:name, :actor, :agent]) |> Map.put(:note, note)

  # A system step is left only by a dirty tree. With no agent at work in the
  # checkout nobody would commit it and the work would sit: it goes to its coder,
  # told what git says is uncommitted, as an agent that left changes is told to
  # commit them (see `uncommitted/3`). One with no coder to run is stopped.
  # Seen live: a service restarted under an agent mid-edit stranded the work.
  defp to_coder(%{actor: :system} = step, %{"kind" => kind, "root" => root} = work)
       when not is_map_key(step, :stop) do
    coder = Enum.find(@templates[kind].steps(), &(&1.actor == :coder))

    if coder && match?({:ok, _provider}, Agents.provider(coder, work)),
      do:
        agent_step(
          coder,
          "These changes in #{root} are uncommitted, and no agent is at work on them. " <>
            "`git status --short` says:\n\n#{Checkout.status(root)}\n" <>
            "Finish them or drop them, commit with git, then end your turn."
        ),
      else: step
  end

  defp to_coder(step, _work), do: step

  defp started(step, work) do
    case to_coder(step, work) do
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

      # A dirty tree with no coder to give it to (see `to_coder/2`): it is stopped.
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
  defp system(%{"root" => root} = work) do
    case to_coder(step(work), work) do
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
        left(work, left)
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

    # The last agent's final words are carried along, for the stop note.
    {times, words} =
      case sent do
        {^seen, times, words} -> {times + 1, words}
        {_other, _times, words} -> {1, words}
        nil -> {1, nil}
      end

    if times < 3, do: say(work, "#{step.name} started (#{step.actor})")
    # Whose turn it is, kept in flight so a restart gives it back (see `kept_turn/2`).
    fly(Map.put(work, "turn", %{"step" => step.name, "note" => step.note}))

    case times < 3 && agent_turn(step, work) do
      false ->
        wait(
          work,
          step,
          "sent to the #{step.actor} a third time with the same tree and note" <> told(words)
        )

      {:error, error} ->
        stop(work, step, "parked: its run ended in error twice: #{inspect(error)}")

      decided ->
        turned(step, work, handoffs, decided, from, {seen, times, words})
    end
  end

  # A work stopped for good while its agent's turn ran: nothing more is done in it.
  defp turned(step, work, handoffs, decided, from, sent) do
    if cancelled?(work),
      do: land(work, landed(:cancelled)),
      else: turned!(step, work, handoffs, decided, from, sent)
  end

  defp turned!(step, %{"id" => id, "root" => root} = work, handoffs, decided, from, sent) do
    # Seen live: a coder's turn that changed nothing logged no reason at all.
    {words, decided} = Map.pop(decided, "said")
    {seen, times, last} = sent
    sent = {seen, times, words || last}
    # What an agent decided is its step's result, at the tree it decided it at.
    if decided != %{}, do: Checkout.record(root, id, step.name, decided)
    # A coder's turn on `work` was given any rejection note still owed: it is answered.
    if step.name == "work", do: Checkout.answered(root, id)
    # Whose commit the tree is, and the commits before the turn that made it, for a
    # template that reads a result by who made it.
    Checkout.record(root, id, "by", %{"step" => step.name, "at" => Checkout.now(), "from" => from})

    said = Enum.reject([decided["status"], decided["note"] || words], &is_nil/1)
    say(work, "#{step.name} turn by the #{step.actor} ended: #{Enum.join(said, ": ")}")
    work = Map.drop(work, ["review", "demo", "note"])
    # The turn is over: none is kept in flight to be given back.
    fly(work)

    # Seen live: a reviewer's check run left untracked logs, and the work sat on
    # promote saying no reason. A dirty system step after a turn is taken as
    # `system/1` takes it: to the coder, else stopped saying what git says.
    case uncommitted(step, root, id) || to_coder(step(work), work) do
      # An agent's step again: an agent that moved nothing is told so, not left
      # sitting on it; the handoffs bound how often.
      %{agent: _} = next when handoffs > 0 ->
        turn(again(next, step), work, handoffs - 1, sent)

      %{agent: _} = left ->
        stop(work, left, "stopped: its #{@handoffs} handoffs are spent" <> told(elem(sent, 2)))

      %{actor: :system} = left ->
        stop(work, left, dirty(root))

      left ->
        left(work, left)
    end
  end

  # Left on an event, kept in flight with its copy, so the event finds it; else
  # landed, waiting on its owner or done.
  defp left(work, %{actor: :external, name: name}),
    do: say(work, "waiting on the event #{name}")

  defp left(%{"id" => id} = work, left) do
    land(work, landed(left))
    if is_nil(left), do: Agents.forget(id)
    Logger.info("[Workflow #{id}] left on #{(is_map(left) && left.name) || "done"}")
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

  # An agent's last words, said in a stop note.
  defp told(nil), do: ""
  defp told(words), do: ". Its last turn ended saying: #{words}"

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
