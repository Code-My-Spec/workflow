# reviewers-get-the-plugin-env: decision note

Callers were grepped in `lib` and `test`: `recipe_env(` (the three recipe calls in
`checkout.ex`), `Workflow.Plugin.dir` and the new `Workflow.Plugin.env`, the
`bash_env` in `Agents.run/3`, and `Checkout.landed?/3` (`Manager` look's `absent/3`,
`Run.merged/1` on resume, `manager_test.exs`, `a_landed_work_resumes_waiting_on_ci_test.exs`).

## (1) Where an agent's shell gets CODEMYSPEC_PLUGIN

In the code no agent's shell got it from the loop, coder included. The one place
that set it was `Checkout.recipe_env/1`, and that only reaches the `just` recipes
the loop runs itself (copy-setup, copy-teardown, run, certify, demo, ci, retry).
Every agent's turn, whatever its role, goes through `Agents.run/3`. There it was
given `context: %{bash_env: %{"AGENT_BROWSER_SESSION" => id}}`, and nothing
else. Alloy's Bash tool runs each command with the BEAM's env, less secret-looking
names, plus that map. The BEAM itself never has CODEMYSPEC_PLUGIN: the loop keeps
the plugin as `Application` env (`:workflow, :plugin`), not as a process variable.
No role check or provider path tells the coder and the reviewer apart. A Claude Code
agent's tools are Alloy's own too, so they get the same context. The new test shows
this: on the old code it fails on the coder first ("coder lacks the plugin"). So the
coder's green certify was the loop's certify run (`recipe_env/1`), not the coder's
shell. The reviewer had only its shell, so its `just certify` failed.

### Fix

`Workflow.Plugin.env/0` is now the one place: `[{"CODEMYSPEC_PLUGIN", <dir, expanded>}]`,
or `[]` with no plugin. `Checkout.recipe_env/1` is `Workflow.Plugin.env() ++ env`,
the same value and order as before. `Agents.run/3` puts the same list into every
agent's `bash_env`, beside `AGENT_BROWSER_SESSION`. With no plugin the variable is
set for nobody. No option was added. Support sessions and the manager are not a
work's agents and are unchanged.

## (2) Why a landed work read as never started after a restart

The "never started" text is the manager's look, in `Manager.absent/3`. It is said
when there is no checkout, no cancel mark, no `stopped` mark, and
`Checkout.landed?/3` says false. Landing (`Run.at_ci/2` / `land/2` -> `disown`)
removes the copy, deletes the branch `<kind>/<id>` and prunes. Pruning keeps
`<id>.json`. With the branch gone, `landed?` had only `commits_merged?`, which
looks for a commit off main's first-parent line whose subject starts
`<kind> <id>: `. Only `Run.story_file/1` makes such a commit for a story or
journey ("the story as handed in"), and `Checkout.commit_files` makes none when
the file is already in the copy as written. On Smart AI Books the stories are in
`.code_my_spec/stories/` in the main copy before they are handed in (pinned at a
commit), so the branch had no commit with that prefix. The coder's commits have
their own subjects. So once the branch was deleted, nothing said the work landed.
And with no `stopped` mark, it read as never started. A restart is when this
shows, because before it the loop still holds the work and the manager was told
of the landing.

`Report.unstarted/1` was checked too. It skips any id with a kept work in
`<id>.json` (which pruning keeps), so it does not list a landed work. A work
waiting at ci keeps its copy and works file, so after a restart it resumes on ci
(f10c3f5) and is reported in flight.

### Fix

`landed?/3` also counts a durable fact the loop already keeps: a `promote` result
`%{"status" => "promoted", "commit" => sha}` in the work's results file
(`<git common dir>/workflow/<id>.json`, kept by pruning), where `sha`, the merge
promote made, is an ancestor of the main copy's HEAD. No new store. In
`Run.merged/1` this only adds a case where promote's merge is in main, which is a
landing.

## Tests

`test/workflow/reviewers_get_the_plugin_env_test.exs` uses temporary git repos, a
fake `:alloy_run`, and no real `~/.workflow` or `.git/workflow`:

- Criterion 1: the coder, reviewer and qa steps run through `Agents.run/2`. Each
  turn's context is used to run Alloy's real Bash tool, which prints
  `${CODEMYSPEC_PLUGIN-unset}`. With a plugin it is the absolute path for every
  role. With none it is `unset`. The inherited process variable is cleared first.
  Fails on the old code: "coder lacks the plugin".
- Criterion 2: `Workflow.Plugin.env/0` gives the variable, or nothing. The
  recipes test (`recipes_know_the_plugin_test.exs`) still passes through it.
- Criterion 3: a story whose file is already in main lands by a `--no-ff` merge,
  with its promote result recorded and its branch deleted. A manager made afresh
  (as after a restart) looks it up and reads "It landed". A promote of a commit
  not in main still reads never started. Fails on the old code: "There is no
  checkout for s1. It was never started."
