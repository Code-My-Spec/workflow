defmodule Workflow.Checkout do
  @moduledoc """
  Everything the loop reads from, or does to, a checkout: its snapshot from git,
  its checks, and the merge that promotes it. The main copy is the first
  worktree git lists (the repository's primary checkout, even when the repo a
  work names is a linked worktree of it), and its branch is whatever it has
  checked out: work lands there. A work
  that names only a repository gets a worktree checkout cut beside it, taken
  away and its branch deleted once the work is done.

  What was found at each tree is kept in the repository's own git directory
  (`workflow/<id>.json`), so the loop needs no store.
  """

  require Logger

  alias Workflow.Sarif

  @doc """
  Makes a worktree checkout for `id` beside `repo`, on a branch named for its
  `kind`, reusing one already there. The first time, before the work ever starts,
  the project's own `just copy-setup` makes it runnable in `project`: what a copy
  needs is the project's business, not the loop's. Cut at the commit `at`, where
  given, else at `repo`'s HEAD. Answers its root, or `{:error, reason}` with the
  recipe's output where copy-setup is missing or fails; that copy is taken away
  again, so a later hand-in sets one up afresh rather than reuse a half-made one.

  One reused, not cut at `at`, merges the main copy's branch first; where that
  merge fails it is aborted, and `{:conflict, reason}` names the conflicting files.
  """
  @spec own(String.t(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          String.t() | {:error, String.t()} | {:conflict, String.t()}
  def own(repo, kind, id, project, at \\ nil) do
    root = root(repo, id)

    cond do
      not File.dir?(root) or copying?(repo, id) -> cut(repo, kind, id, project, at)
      at -> root
      true -> take_main(repo, root)
    end
  end

  @doc """
  Whether the copy for `id` beside `repo` was begun and its copy-setup has not
  yet passed: a half-made copy, cut short (seen live: by a restart), never
  reused as finished.
  """
  @spec copying?(String.t(), String.t()) :: boolean()
  def copying?(repo, id), do: File.exists?(copying(repo, id))

  # Marked before the copy is begun, cleared once copy-setup passes.
  defp copying(repo, id), do: Path.rootname(path(repo, id)) <> ".copying"

  # What a copy cut short left, its worktree and its branch, taken away so it is
  # made afresh.
  defp unmake(repo, root, branch) do
    git(repo, ["worktree", "remove", "--force", root])
    File.rm_rf(root)
    git(repo, ["worktree", "prune"])
    git(repo, ["branch", "-D", branch])
  end

  # Seen live: a story handed in again by id resumed a kept branch that had never
  # merged main, ran the old justfile's `run` recipe, and stopped the same way thrice.
  defp take_main(repo, root) do
    with %{branch: main} <- landing(repo),
         {:error, why} <- git(root, ["merge", "--no-edit", main]) do
      {_listed, files} = git(root, ~w(diff --name-only --diff-filter=U))
      git(root, ~w(merge --abort))

      named =
        if files == "",
          do: why,
          else: "conflicting files: " <> Enum.join(String.split(files, "\n"), ", ")

      {:conflict,
       "the merge of `#{main}` into the work's branch conflicted (#{named}). " <>
         "Merge it, resolve, and commit, then hand the work in again."}
    else
      _merged_or_no_main -> root
    end
  end

  defp cut(repo, kind, id, project, at) do
    root = root(repo, id)
    branch = "#{kind}/#{id}"
    mark = copying(repo, id)
    if File.exists?(mark), do: unmake(repo, root, branch)
    File.mkdir_p!(Path.dirname(mark))
    File.write!(mark, "")
    add = ["worktree", "add", "-b", branch, root | List.wrap(at)]

    # A branch left by a cut cut short (`a branch named ... already exists`): made afresh.
    {:ok, _} =
      with {:error, _} <- git(repo, add) do
        unmake(repo, root, branch)
        git(repo, add)
      end

    here = Path.join(root, project || ".")

    case cmd("just", ["copy-setup"], cd: here, stderr_to_stdout: true, env: recipe_env([])) do
      {_out, 0} ->
        File.rm(mark)
        root

      {out, status} ->
        git(repo, ["worktree", "remove", "--force", root])
        git(repo, ["branch", "-D", "#{kind}/#{id}"])
        File.rm(mark)

        missing =
          if out =~ "does not contain recipe", do: "this project has no copy-setup recipe. "

        {:error,
         "#{missing}`just copy-setup` failed in #{project || "."} (exit #{status}): #{String.trim(out)}"}
    end
  end

  # The project's own `just copy-teardown`, before its copy is taken away: what
  # copy-setup made for it (a test database) goes with it. One that fails is
  # logged, and the copy is taken away all the same, so none is ever stranded.
  defp teardown(repo, id, project) do
    here = Path.join(root(repo, id), project || ".")

    with true <- File.dir?(here),
         {out, status} when status != 0 <-
           cmd("just", ["copy-teardown"], cd: here, stderr_to_stdout: true, env: recipe_env([])) do
      Logger.warning(
        "[Workflow #{id}] `just copy-teardown` in #{here} failed (exit #{status}); " <>
          "the copy is removed anyway: #{String.trim(out)}"
      )
    end

    :ok
  end

  @doc "Where the worktree checkout for `id` beside `repo` is, or would be."
  @spec root(String.t(), String.t()) :: String.t()
  def root(repo, id), do: "#{repo}-#{id}"

  @doc """
  Nil for a plain name (letters, digits and dashes only), else the refusal naming
  it: the one check on a work id or an inbox name, at every door it enters, since
  each becomes a path, a branch or a checkout folder.
  """
  @spec refused(term()) :: String.t() | nil
  def refused(name) do
    unless is_binary(name) and name =~ ~r/\A[A-Za-z0-9-]+\z/,
      do:
        "Refused: #{inspect(name)} is not a plain name (only letters, digits and dashes). " <>
          "Nothing was made from it."
  end

  @doc """
  Runs `just copy-teardown` in `project` of the worktree checkout made for `id`
  beside `repo`, removes it, and deletes its branch.
  """
  @spec disown(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def disown(repo, kind, id, project \\ nil) do
    teardown(repo, id, project)
    git(repo, ["worktree", "remove", root(repo, id)])
    git(repo, ["branch", "-D", "#{kind}/#{id}"])
    prune(repo, id)
  end

  @doc """
  Takes away the worktree checkout made for `id` beside `repo` even with changes
  in it, after `just copy-teardown` there as `disown/4` does, and deletes its
  branch: what stopping a work for good does.
  """
  @spec remove(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def remove(repo, kind, id, project \\ nil) do
    teardown(repo, id, project)
    git(repo, ["worktree", "remove", "--force", root(repo, id)])
    git(repo, ["branch", "-D", "#{kind}/#{id}"])
    prune(repo, id)
  end

  # What is the work `id`'s alone under `<git common dir>/workflow`, once it is
  # done or stopped for good: the run folders at each tree its results name, where
  # no other work's results name that tree too, and its conversation file. Kept:
  # each tree's `log` (the line its landing or stop was said in) and the results
  # file itself, which holds its stop mark and what `look` and `outcome` read.
  defp prune(repo, id) do
    with {:ok, git_dir} <- git(repo, ~w(rev-parse --path-format=absolute --git-common-dir)) do
      workflow = Path.join(git_dir, "workflow")

      others =
        for file <- Path.wildcard(Path.join(workflow, "*.json")),
            Path.basename(file, ".json") != id,
            tree <- trees(file),
            into: MapSet.new(),
            do: tree

      for tree <- trees(Path.join(workflow, "#{id}.json")),
          not MapSet.member?(others, tree),
          at = Path.join([workflow, "analysis", tree]),
          {:ok, names} <- [File.ls(at)],
          name <- names,
          run = Path.join(at, name),
          File.dir?(run),
          do: File.rm_rf(run)

      File.rm(Path.join([workflow, "conversations", "#{id}.jsonl"]))
    end

    :ok
  end

  # The trees a results file keeps what was found at: its keys that are tree ids.
  defp trees(file) do
    with {:ok, json} <- File.read(file),
         {:ok, %{} = kept} <- Jason.decode(json) do
      for {key, %{}} <- kept, key =~ ~r/\A[0-9a-f]{40,64}\z/, do: key
    else
      _none -> []
    end
  end

  @doc """
  Marks the work for `id` stopped for good, in the git directory of `repo` (so
  the mark outlives its checkout). Unlike `stop/4`, handing it in again does not
  clear it.
  """
  @spec cancel(String.t(), String.t()) :: :ok
  def cancel(repo, id) do
    update(repo, id, &Map.put(&1, "cancelled", %{"at" => now()}))
    :ok
  end

  @doc "Whether the work for `id` was stopped for good; false where `dir` is no git checkout."
  @spec cancelled?(String.t() | nil, String.t()) :: boolean()
  def cancelled?(dir, id) do
    is_binary(dir) and File.dir?(dir) and
      match?({:ok, _}, git(dir, ~w(rev-parse --path-format=absolute --git-common-dir))) and
      Map.has_key?(results(dir, id), "cancelled")
  end

  @doc """
  Removes each of `paths` there is in the checkout and commits that removal in
  one commit, or none if none is there.
  """
  @spec remove_files(String.t(), [String.t()], String.t()) :: :ok | :unchanged | {:error, term()}
  def remove_files(root, paths, message) do
    present = Enum.filter(paths, &File.exists?(Path.join(root, &1)))

    with false <- present == [],
         {:ok, _removed} <- git(root, ["rm", "-q", "--" | present]),
         {:ok, _committed} <- git(root, ["commit", "-m", message, "--" | present]) do
      :ok
    else
      true -> :unchanged
      {:error, why} -> {:error, why}
    end
  end

  @doc """
  Where work cut from `repo` lands: the repository's primary checkout (the first
  worktree git lists, even when `repo` is a linked worktree of it) and the branch
  it has checked out. `nil` when `repo` is not a git checkout.
  """
  @spec landing(String.t() | nil) :: %{folder: String.t(), branch: String.t()} | nil
  def landing(repo) do
    with true <- is_binary(repo) and File.dir?(repo),
         {:ok, "worktree " <> listed} <- git(repo, ~w(worktree list --porcelain)),
         folder = listed |> String.split("\n") |> hd(),
         {:ok, branch} <- git(folder, ~w(rev-parse --abbrev-ref HEAD)) do
      %{folder: folder, branch: branch}
    else
      _none -> nil
    end
  end

  @doc """
  The full sha of the commit `at` (the main copy's HEAD where `at` is nil) in
  `repo`'s main copy, fetched from its remotes first (one with no remote fetches
  nothing): `{:ok, sha}`, or `:none` when there is no such commit.
  """
  @spec pinned(String.t() | nil, String.t() | nil) :: {:ok, String.t()} | :none
  def pinned(repo, at) do
    with %{folder: folder} <- landing(repo),
         _fetched <- fetched(folder),
         {:ok, sha} <-
           git(folder, ["rev-parse", "--verify", "--quiet", "#{at || "HEAD"}^{commit}"]) do
      {:ok, sha}
    else
      _none -> :none
    end
  end

  defp fetched(folder) do
    with {:ok, "" <> remotes} when remotes != "" <- git(folder, ["remote"]),
         do: git(folder, ["fetch", "--all", "--quiet"])
  end

  @doc "The file `path` as it is at the commit `sha` of `repo`'s main copy (`git show <sha>:<path>`)."
  @spec show(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def show(repo, sha, path) do
    with %{folder: folder} <- landing(repo),
         {:ok, "blob"} <- git(folder, ["cat-file", "-t", "#{sha}:#{path}"]) do
      git(folder, ["show", "#{sha}:#{path}"])
    else
      {:error, why} -> {:error, why}
      _none -> {:error, "no file #{path} at #{sha}"}
    end
  end

  @doc "`git diff <old>..<new> -- <path>` in `repo`'s main copy."
  @spec diff(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def diff(repo, old, new, path) do
    with %{folder: folder} <- landing(repo),
         {:ok, diff} <- git(folder, ["diff", "#{old}..#{new}", "--", path]) do
      diff
    else
      _none -> ""
    end
  end

  @doc "Whether the commit `old` comes before the commit `new` in `repo`'s main copy."
  @spec before?(String.t(), String.t(), String.t()) :: boolean()
  def before?(repo, old, new) do
    with %{folder: folder} <- landing(repo),
         {:ok, _ancestor} <- git(folder, ["merge-base", "--is-ancestor", old, new]) do
      old != new
    else
      _none -> false
    end
  end

  @doc """
  Whether the work `kind`/`id` landed: its branch, or a commit of its own (named
  `<kind> <id>: ...`, as its story or issue file's is), is merged in the main
  copy. Stopping a work commits in the main copy too; that commit is not a landing.
  """
  @spec landed?(String.t() | nil, String.t(), String.t()) :: boolean()
  def landed?(repo, kind, id) do
    with %{folder: folder} <- landing(repo) do
      branch_merged?(folder, "#{kind}/#{id}") or commits_merged?(folder, "#{kind} #{id}: ")
    else
      _none -> false
    end
  end

  # In the main copy's branch, but merged into it: a branch just cut, with no
  # commits of its own, sits on the main branch's own line and has not landed.
  defp branch_merged?(folder, branch) do
    with {:ok, tip} <- git(folder, ["rev-parse", "--verify", "-q", "refs/heads/" <> branch]),
         {:ok, _} <- git(folder, ["merge-base", "--is-ancestor", tip, "HEAD"]),
         {:ok, line} <- git(folder, ~w(rev-list --first-parent HEAD)) do
      tip not in String.split(line, "\n", trim: true)
    else
      _none -> false
    end
  end

  # Merged into it, as branch_merged? asks: an issue's file is committed on the
  # main branch's own line under the same prefix, and that is not a landing.
  defp commits_merged?(folder, prefix) do
    with {:ok, commits} <-
           git(folder, ["log", "-F", "--grep=" <> prefix, "--format=%H %s", "HEAD"]),
         {:ok, line} <- git(folder, ~w(rev-list --first-parent HEAD)) do
      line = String.split(line, "\n", trim: true)

      commits
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, " ", parts: 2))
      |> Enum.any?(fn [sha, subject] ->
        String.starts_with?(subject, prefix) and
          not String.starts_with?(subject, prefix <> "stopped") and sha not in line
      end)
    else
      _none -> false
    end
  end

  # A git status that never takes the index lock: a read beside another
  # hand-in's add or commit would make that one fail on index.lock.
  @no_lock [env: [{"GIT_OPTIONAL_LOCKS", "0"}]]

  @doc "The snapshot a template decides from, or `:none` outside a git checkout."
  @spec snapshot(String.t(), String.t()) :: map() | :none
  def snapshot(root, id) do
    with {:ok, head} <- git(root, ~w(rev-parse HEAD^{tree})),
         {:ok, "worktree " <> listed} <- git(root, ~w(worktree list --porcelain)),
         main_copy = listed |> String.split("\n") |> hd(),
         {:ok, main} <- git(main_copy, ~w(rev-parse --abbrev-ref HEAD)),
         {:ok, commits} <- git(root, ["rev-list", "--count", "--no-merges", "#{main}..HEAD"]),
         {:ok, status} <- git(root, ~w(status --porcelain), @no_lock) do
      %{
        head: head,
        main: main,
        main_copy: main_copy,
        commits: String.to_integer(commits),
        dirty?: status != "",
        results: results(root, id)
      }
    else
      _no_git -> :none
    end
  end

  @doc "Keeps what `step` found at the checkout's tree as it stands now."
  @spec record(String.t(), String.t(), String.t(), map()) :: :ok
  def record(root, id, step, result) do
    {:ok, head} = git(root, ~w(rev-parse HEAD^{tree}))

    update(
      root,
      id,
      &Map.update(&1, head, %{step => result}, fn at -> Map.put(at, step, result) end)
    )

    # The one point a report is sent from: the work's whole picture, to the server.
    Workflow.Report.recorded(root, id)
  end

  @doc "The commit the checkout is at, or nil where it has none."
  @spec commit(String.t()) :: String.t() | nil
  def commit(root) do
    case git(root, ~w(rev-parse HEAD)) do
      {:ok, commit} -> commit
      _none -> nil
    end
  end

  @doc """
  Keeps the work as it was handed in, beside its results, less the `agent` and
  `agents` entries, since either may carry a provider's key. A work handed in
  again replaces what was kept, and is no longer stopped.
  """
  @spec keep(String.t(), String.t(), map()) :: :ok
  def keep(root, id, work) do
    update(root, id, fn found ->
      found
      |> Map.put("work", Map.drop(work, ["agent", "agents"]))
      |> Map.delete("stopped")
    end)

    :ok
  end

  @doc """
  Forgets the `run` and `certify` results kept for the checkout's current tree,
  and the work's `stopped`, so a work handed in again at an unchanged tree runs
  its checks afresh (seen live: a failure from a missing .env.test, fixed, came
  back every hand-in). Nothing is done outside a git checkout.
  """
  @spec afresh(String.t(), String.t()) :: :ok
  def afresh(root, id) do
    with true <- is_binary(root) and File.dir?(root),
         {:ok, _git_dir} <- git(root, ~w(rev-parse --path-format=absolute --git-common-dir)),
         {:ok, tree} <- git(root, ~w(rev-parse HEAD^{tree})) do
      update(root, id, fn found ->
        found
        |> Map.delete("stopped")
        |> then(fn kept ->
          case kept[tree] do
            %{} = at -> Map.put(kept, tree, Map.drop(at, ["run", "certify"]))
            _none -> kept
          end
        end)
      end)

      # `analyse/3` reads a recipe's latest run at the tree rather than run it again:
      # marked afresh, the next makes a new run folder. The evidence is kept.
      dir_analysis = analysis_dir(root)

      for recipe <- ["run", "certify"], {run, _meta} <- [Sarif.latest(dir_analysis, recipe)] do
        Sarif.merge_meta(run, %{"afresh" => true})
      end
    end

    :ok
  end

  @doc "Keeps why the loop gave up on the work at `step`, until it is handed in again."
  @spec stop(String.t(), String.t(), String.t(), String.t()) :: :ok
  def stop(root, id, step, reason) do
    stopped = %{"step" => step, "reason" => reason, "at" => now()}
    update(root, id, &Map.put(&1, "stopped", stopped))
    :ok
  end

  @doc "Why the loop gave up on the work, or `nil` while it has not."
  @spec stopped(String.t(), String.t()) :: map() | nil
  def stopped(root, id), do: root |> results(id) |> Map.get("stopped")

  @doc "Keeps what the work's owner said to it, beside its results, until an agent's next turn takes it."
  @spec say(String.t(), String.t(), String.t()) :: :ok
  def say(root, id, said) do
    update(root, id, &Map.update(&1, "said", [said], fn was -> was ++ [said] end))
    :ok
  end

  @doc """
  Keeps the owner's rejection note beside the work's results, under no tree, so
  it outlives a merge or a commit, until `answered/2` says the coder has had it.
  """
  @spec reject(String.t(), String.t(), String.t()) :: :ok
  def reject(root, id, note) do
    update(root, id, &Map.put(&1, "rejected", note))
    :ok
  end

  @doc "Forgets the owner's rejection note: the coder has had a turn with it."
  @spec answered(String.t(), String.t()) :: :ok
  def answered(root, id) do
    update(root, id, &Map.delete(&1, "rejected"))
    :ok
  end

  @doc "`say/3` for a work with a checkout at `root`, as POST /work/say does; `:none` with none."
  @spec say_to(String.t(), String.t(), String.t()) :: :ok | :none | term()
  def say_to(root, id, said) do
    with true <- File.dir?(root) or :none,
         %{} <- snapshot(root, id),
         do: say(root, id, said)
  end

  @doc "Everything said to the work since it was last taken, and forgets it, so each is said once."
  @spec heard(String.t(), String.t()) :: [String.t()]
  def heard(root, id) do
    root |> update(id, &Map.delete(&1, "said")) |> Map.get("said", [])
  end

  @doc "Writes each `{path, content}` and commits those that changed in one commit, or none if none did."
  @spec commit_files(String.t(), [{String.t(), String.t()}], String.t()) ::
          :ok | :unchanged | {:error, term()}
  def commit_files(root, files, message) do
    # One write and commit at a time in a checkout: two works handed in at once
    # collided on git's index lock, and the second's file went unrecorded. The
    # lock is the checkout, as `promote/2`'s is; the id's second part is who asks.
    :global.trans({{__MODULE__, root}, self()}, fn -> commit_files!(root, files, message) end)
  end

  defp commit_files!(root, files, message) do
    # Unchanged only when committed as it is: a file left written by a failed
    # commit is committed now.
    changed =
      Enum.reject(files, fn {path, content} ->
        File.read(Path.join(root, path)) == {:ok, content} and not changed?(root, path)
      end)

    paths = Enum.map(changed, &elem(&1, 0))

    with false <- changed == [],
         :ok <- write_all(root, changed),
         {:ok, _added} <- git(root, ["add", "--" | paths]),
         {:ok, _committed} <- git(root, ["commit", "-m", message, "--" | paths]) do
      :ok
    else
      true -> :unchanged
      {:error, why} -> {:error, why}
    end
  end

  defp write_all(root, files) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      file = Path.join(root, path)

      case File.mkdir_p(Path.dirname(file)) do
        :ok ->
          case File.write(file, content) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  @doc "The output of `git status --short` in the checkout, as git gives it."
  @spec status(String.t()) :: String.t()
  def status(root) do
    {out, _status} =
      cmd("git", ~w(status --short), [cd: root, stderr_to_stdout: true] ++ @no_lock)

    out
  end

  @doc "Whether `path` in the checkout has changes not yet committed."
  @spec changed?(String.t(), String.t()) :: boolean()
  def changed?(root, path) do
    # Its output alone: git warns on stderr of a directory not there yet.
    case cmd("git", ["status", "--porcelain", "--", path], [cd: root] ++ @no_lock) do
      {"", 0} -> false
      _changed -> true
    end
  end

  @doc "The checkout's changed paths when every one is tracked and named in .gitignore, else `[]`."
  @spec ignored_changes(String.t()) :: [String.t()]
  def ignored_changes(root) do
    # Its output untrimmed: each line's path starts at the fourth character.
    with {status, 0} <- cmd("git", ~w(status --porcelain), [cd: root] ++ @no_lock),
         {:ok, ignored} <- git(root, ~w(ls-files -c -i --exclude-standard)),
         changed =
           status |> String.split("\n", trim: true) |> Enum.map(&String.slice(&1, 3..-1//1)),
         true <- changed != [] and changed -- String.split(ignored, "\n") == [] do
      changed
    else
      _other -> []
    end
  end

  @doc "The work last kept for `id`, as it was handed in, or `%{}` before one is."
  @spec kept(String.t(), String.t()) :: map()
  def kept(root, id), do: root |> results(id) |> Map.get("work", %{})

  @doc """
  What a work that ended done left, read from its results beside `dir` (its
  checkout, or the repository it was cut from): the last decision note, the
  reviewer's where there is one, and the commit it landed as with git's
  shortstat line for it, or nil where nothing landed.
  """
  @spec outcome(String.t(), String.t()) :: %{
          note: String.t() | nil,
          landed: {String.t(), String.t() | nil} | nil
        }
  def outcome(dir, id) do
    # The tree results only: each value a step's result.
    trees =
      dir
      |> results(id)
      |> Map.values()
      |> Enum.filter(&(is_map(&1) and Enum.all?(Map.values(&1), fn r -> is_map(r) end)))

    last =
      Enum.max_by(
        trees,
        &{Map.has_key?(&1, "promote"), get_in(&1, ["by", "at"]) || ""},
        fn -> %{} end
      )

    by = get_in(last, ["by", "step"])
    note = get_in(last, ["review", "note"]) || (by && get_in(last, [by, "note"]))

    landed =
      case last["promote"] do
        %{"status" => "promoted", "commit" => commit} ->
          with %{folder: folder} <- landing(dir),
               {:ok, stat} <- git(folder, ["diff", "--shortstat", commit <> "^1", commit]) do
            {commit, stat}
          else
            _none -> {commit, nil}
          end

        _not_landed ->
          nil
      end

    %{note: note, landed: landed}
  end

  @doc "The output of `git diff --stat <main>...HEAD` for the checkout."
  @spec diff_stat(String.t(), String.t()) :: String.t()
  def diff_stat(root, main) do
    {:ok, out} = git(root, ["diff", "--stat", "#{main}...HEAD"])
    out
  end

  @doc "The output of `git diff <a> <b> --stat -- <path>` for the checkout."
  @spec diff_stat(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def diff_stat(root, a, b, path) do
    {:ok, out} = git(root, ["diff", a, b, "--stat", "--", path])
    out
  end

  @doc """
  Whether none of the paths that differ between `tree` and HEAD is one the work
  changes against `main` (`git diff <main>...HEAD`): what came in since was main's.
  False where either cannot be read.
  """
  @spec only_main_since?(String.t(), String.t(), String.t()) :: boolean()
  def only_main_since?(root, tree, main) do
    with {:ok, since} <- git(root, ["diff", "--name-only", tree, "HEAD"]),
         {:ok, own} <- git(root, ["diff", "--name-only", "#{main}...HEAD"]) do
      MapSet.disjoint?(MapSet.new(String.split(since)), MapSet.new(String.split(own)))
    else
      _unread -> false
    end
  end

  @doc """
  Merges the main copy's branch, then analyses `dir` of the checkout with the
  recipe certify, for the work `id` (see `analyse/6`).
  """
  @spec certify(String.t(), map(), String.t() | nil, String.t()) :: map()
  def certify(root, %{main: main}, dir, id) do
    case git(root, ["merge", "--no-edit", main]) do
      {:ok, _merged} ->
        analyse(root, dir, "certify", [], nil, "certify/#{id}")

      {:error, conflict} ->
        git(root, ~w(merge --abort))
        failed("Merging `#{main}` conflicts: #{conflict} Merge it, resolve, and commit.")
    end
  end

  @doc "Analyses `dir` of the checkout as it stands, with the recipe run, for the work `id`."
  @spec test(String.t(), String.t() | nil, String.t()) :: map()
  def test(root, dir, id), do: analyse(root, dir, "run", [], nil, "run/#{id}")

  @doc """
  Runs the project's demo, as `just demo <dir>` into the `demo` folder of the tree's
  analysis directory, the way certify is run. A project with no `demo` recipe has no
  demo: `%{"status" => "none"}`, not a failure.
  """
  @spec demo(String.t(), String.t() | nil) :: map()
  def demo(root, dir) do
    case cmd("just", ["--show", "demo"], cd: Path.join(root, dir || "."), stderr_to_stdout: true) do
      {_shown, 0} -> analyse(root, dir, "demo", [], "demo")
      _no_recipe -> %{"status" => "none"}
    end
  end

  @doc """
  Analyses `dir` of the checkout with the recipe named `recipe`: runs `just <recipe>
  <directory>` in the project, handed a run folder of its own
  (`<git common dir>/workflow/analysis/<tree>/<unix time>/`) that holds the SARIF
  files it writes and one meta.json for the run (recipe, at, took_ms, exit), and
  reads the verdict from there. A tree already analysed with `recipe` has its
  latest run read, not run again. With `into`, the recipe is given that folder of
  the tree's analysis directory instead.

  With a `context` (`certify/<work id>`, `run/<work id>`), the recipe is also
  given EVIDENCE_CONTEXT as that and one EVIDENCE_CORRELATION uuid, and the
  evidence it leaves in the project is sent up afterwards (`Workflow.Upload`).
  The verdict is the recipe's exit, whatever becomes of the upload.
  """
  @spec analyse(
          String.t(),
          String.t() | nil,
          String.t() | [String.t()],
          [
            {String.t(), String.t()}
          ],
          String.t() | nil,
          String.t() | nil
        ) ::
          map()
  def analyse(root, dir, recipe, env \\ [], into \\ nil, context \\ nil) do
    dir_analysis = analysis_dir(root)
    # A recipe with arguments is kept in meta.json by its whole command, its
    # environment first, so each variant at one tree is run.
    args = List.wrap(recipe)
    recipe = Enum.join(Enum.map(env, fn {k, v} -> "#{k}=#{v}" end) ++ args, " ")

    latest =
      if into do
        target = Path.join(dir_analysis, into)
        meta = Sarif.meta(target)
        if meta["recipe"] == recipe and meta["afresh"] != true, do: {target, meta}
      else
        Sarif.latest(dir_analysis, recipe)
      end

    # A recipe that failed without leaving an error result still failed: its exit is kept.
    if latest do
      {target, ran} = latest

      Sarif.verdict(
        target,
        ran["exit"],
        "`just #{recipe}` failed at this tree (exit #{ran["exit"]})."
      )
    else
      run_recipe(root, dir, dir_analysis, args, env, recipe, into, context)
    end
  end

  # What a recipe the loop runs is given: the call's own `env`, and CODEMYSPEC_PLUGIN
  # as the plugin folder in use, absolute, so a project's recipes can find it. Not
  # set with no plugin.
  defp recipe_env(env) do
    case Workflow.Plugin.dir() do
      nil -> env
      dir -> [{"CODEMYSPEC_PLUGIN", Path.expand(dir)} | env]
    end
  end

  defp run_recipe(root, dir, dir_analysis, args, env, recipe, into, context) do
    target = if into, do: Path.join(dir_analysis, into), else: Sarif.new_run(dir_analysis)
    project = Path.join(root, dir || ".")
    started = System.monotonic_time(:millisecond)
    File.mkdir_p!(target)
    before = context && Workflow.Upload.evidence(project)

    {output, status} =
      cmd("just", args ++ [target],
        cd: project,
        stderr_to_stdout: true,
        env: recipe_env(Workflow.Upload.env(context) ++ env)
      )

    if context, do: Workflow.Upload.upload(project, before)

    took_ms = System.monotonic_time(:millisecond) - started

    Logger.info("[Workflow] #{recipe} in #{project}: exit #{status} in #{took_ms}ms")

    Sarif.merge_meta(target, %{
      "tree" => Path.basename(dir_analysis),
      "recipe" => recipe,
      "at" => now(),
      "took_ms" => took_ms,
      "exit" => status
    })

    log(Path.join(dir_analysis, "log"), "just #{recipe}: exit #{status} in #{took_ms}ms")

    Sarif.verdict(target, status, output)
  end

  @doc """
  The path of the work's log at the tree the checkout is at now: `log` in the
  tree's analysis directory, beside its SARIF files and meta.json. Nil where
  there is no checkout or no git.
  """
  @spec log(String.t()) :: String.t() | nil
  def log(root) do
    with true <- File.dir?(root),
         {:ok, git_dir} <- git(root, ~w(rev-parse --path-format=absolute --git-common-dir)),
         {:ok, tree} <- git(root, ~w(rev-parse HEAD^{tree})) do
      Path.join([git_dir, "workflow", "analysis", tree, "log"])
    else
      _none -> nil
    end
  end

  @doc "Appends `line` to the log at `path`, with the time it is written."
  @spec log(String.t(), String.t()) :: :ok
  def log(path, line) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#{now()} #{line}\n", [:append])
  end

  defp analysis_dir(root) do
    {:ok, git_dir} = git(root, ~w(rev-parse --path-format=absolute --git-common-dir))
    {:ok, tree} = git(root, ~w(rev-parse HEAD^{tree}))
    Path.join([git_dir, "workflow", "analysis", tree])
  end

  @doc "The time now, in UTC, as ISO 8601: the one clock every result and log line is stamped by."
  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp failed(note), do: %{"status" => "failed", "note" => note}

  @doc "Merges the checkout's commit into the main copy, as one merge commit."
  @spec promote(String.t(), map()) :: map()
  def promote(root, %{main_copy: main_copy}) do
    # The commit, not the branch: a detached checkout has no branch to name.
    {:ok, commit} = git(root, ~w(rev-parse HEAD))

    # One merge at a time into the main copy: two works can finish together.
    # The lock is the main copy; the id's second part is who asks for it.
    :global.trans({{__MODULE__, main_copy}, self()}, fn ->
      push = Application.get_env(:workflow, :push, %{})
      remote = push["remote"] || "origin"
      branch = push["branch"] || "dev"
      {:ok, before} = git(main_copy, ~w(rev-parse HEAD))

      with :ok <- follow(main_copy, remote, branch) do
        land(main_copy, commit, remote, branch, before)
      end
    end)
  end

  # Takes the remote branch's new commits into the main copy before a work
  # merges, so the push after it is a fast-forward. No such remote, or no such
  # branch on it yet, takes nothing: only a merge left in conflict has one to
  # abort. A conflict is aborted and stops the work.
  defp follow(main_copy, remote, branch) do
    with {:ok, _url} <- git(main_copy, ["remote", "get-url", remote]),
         {:ok, _fetched} <- git(main_copy, ["remote", "update", remote]),
         {:error, why} <- git(main_copy, ["merge", "--no-edit", "#{remote}/#{branch}"]),
         {:ok, _aborted} <- git(main_copy, ~w(merge --abort)) do
      conflicted("The main copy does not merge #{remote} #{branch}: #{why}")
    else
      _taken_or_none -> :ok
    end
  end

  defp conflicted(why) do
    note = "#{why}\n\nNothing was landed or pushed. Hand in an issue with this conflict."

    if Workflow.Manager.configured(),
      do: Task.start(fn -> Workflow.Messages.say("manager", "workflow", note) end)

    %{"status" => "conflicted", "note" => note}
  end

  defp land(main_copy, commit, remote, branch, before) do
    case git(main_copy, ["merge", "--no-ff", "--no-edit", commit]) do
      {:ok, _merged} ->
        {:ok, landed} = git(main_copy, ~w(rev-parse HEAD))

        # No such remote pushes nothing. A refused push never holds landing;
        # the next push carries everything. One that went is said on the channel.
        with {:ok, _url} <- git(main_copy, ["remote", "get-url", remote]),
             {:error, why} <- pushed(main_copy, remote, branch, landed) do
          note =
            "Landed, but the push to #{remote} #{branch} failed: #{why}\n\n" <>
              "Hand in an issue with this failure now; do not ask first."

          # Told once, in the background as the loop's landings are; nothing retries.
          if Workflow.Manager.configured(),
            do: Task.start(fn -> Workflow.Messages.say("manager", "workflow", note) end)

          %{"status" => "promoted", "note" => note, "commit" => landed}
        else
          _pushed_or_no_remote -> %{"status" => "promoted", "commit" => landed}
        end

      {:error, why} ->
        git(main_copy, ~w(merge --abort))

        # The remote's new commits, just taken, are what the work conflicts with.
        if git(main_copy, ~w(rev-parse HEAD)) != {:ok, before} do
          conflicted("The work does not merge over #{remote} #{branch}'s new commits: #{why}")
        else
          %{
            "status" => "refused",
            "note" =>
              "It does not merge into the main copy (#{String.slice(why, 0, 400)}). " <>
                "Merge the main copy's branch into yours, resolve it, and commit."
          }
        end
    end
  end

  defp pushed(main_copy, remote, branch, commit) do
    with {:ok, _out} = ok <- git(main_copy, ["push", remote, "HEAD:" <> branch]) do
      Workflow.Server.push("pushed", %{"branch" => branch, "commit" => commit})
      ok
    end
  end

  defp results(root, id) do
    with {:ok, json} <- File.read(path(root, id)),
         {:ok, %{} = kept} <- Jason.decode(json) do
      kept
    else
      _none -> %{}
    end
  end

  # One read, change and write of a work's results file at a time: two updates
  # close together each read it before the other wrote, and one was lost. The
  # lock is the file. Writes only a change; gives what was found.
  defp update(root, id, change) do
    path = path(root, id)

    :global.trans({{__MODULE__, :results, path}, self()}, fn ->
      found = results(root, id)
      kept = change.(found)

      if kept != found do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Jason.encode!(kept))
      end

      found
    end)
  end

  defp path(root, id) do
    {:ok, git_dir} = git(root, ~w(rev-parse --path-format=absolute --git-common-dir))
    Path.join([git_dir, "workflow", "#{id}.json"])
  end

  defp git(dir, args, opts \\ []) do
    case cmd("git", args, [cd: dir, stderr_to_stdout: true] ++ opts) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _status} -> {:error, String.trim(out)}
    end
  end

  @doc """
  The one place the loop runs a command (`just`, git) in a project: `run`
  (`System.cmd/3`, or what a test puts in its place), with the release's own
  variables (RELEASE_*, ERL_*, MIX_ENV, ROOTDIR, BINDIR, EMU, PROGNAME) taken out
  of the child's environment, so the project's commands use its own runtime.
  Every other variable passes through, and any `:env` the caller gives still applies.
  """
  @spec cmd(String.t(), [String.t()], keyword(), function()) ::
          {Collectable.t(), non_neg_integer()}
  def cmd(command, args, opts, run \\ Application.get_env(:workflow, :cmd, &System.cmd/3)) do
    given = Keyword.get(opts, :env, [])
    set = MapSet.new(given, fn {name, _} -> to_string(name) end)

    unset =
      for {name, _} <- System.get_env(), release_var?(name), name not in set, do: {name, nil}

    opts = Keyword.put(opts, :env, unset ++ given)
    run.(command, args, opts)
  end

  defp release_var?(name),
    # Not all of MIX_*: a person's MIX_HOME says where their own mix keeps hex.
    do:
      name in ~w(ROOTDIR BINDIR EMU PROGNAME MIX_ENV) or
        String.starts_with?(name, ["RELEASE_", "ERL_"])
end
