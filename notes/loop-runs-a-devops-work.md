# loop-runs-a-devops-work: decision note

## How it is handed in

A new work kind, `devops` (`Workflow.Devops`, a `Workflow.Template` beside
`Issue`, `Story` and `Journey`, listed in `Run.kinds/0`). The manager's
`hand_in` takes, exactly as built:

- `kind`: `"devops"`
- `id`: the work's plain id
- `action`: `"check"` (every probe) or `"apply"` (each apply, then its probe)
- `environment`: the environment whose `devops.yml` lines are run (`"uat"`, ...)

`action` and `environment` are added to `@handed_in` and to the tool's
properties. No config option is added. The work is cut, run and reported as
any work is: a worktree from the manager's repo, the works file, `Run.start/1`.

## Steps

`resolve` (system), `probe` (system), `fix` (coder), `person` (owner).

1. **resolve**: `elixir <plugin>/bin/resolve.exs devops.yml` in the project's
   directory. Any `refused` event stops the work naming each line; so does a
   non-zero exit, no devops.yml, or no line for the environment. The manager's
   `hand_in` runs the same resolve against the main copy first and refuses the
   work, naming each line, before anything is cut or run.
2. **probe**: for each resolved step of the environment, in file order, its
   apply (an apply work, first round only) then its probe, each a script of
   the plugin run with `<environment> <settings...>` through `Checkout.cmd/3`
   with the plugin's env. One event a stdout line (a non-JSON line is kept as
   `{"event": "output", "text": line}`), tagged `step` and `phase`. The exit
   code is pass (0) or fail. The probe is the truth: a step's status is its
   probe's, whatever its apply said.
3. **fix**: a failed probe goes to the coder, with the template's devops skill
   (`<plugin>/skills/devops`, passed as the agent's `skills`, which
   `Agents.skills/2` now also reads) and the provider's words (the failed
   probe's last `message`/`reason`/text) in its note. After its turn the
   probes run again.
4. **person**: once the retries are spent the work waits on a person: the
   stop is kept as `waiting on its owner: ...` with the last probe's words, so
   the report's status is "waiting on a person".

## Retries

**3**, set by `@retries` in `lib/workflow/devops.ex` (read by
`Workflow.Devops.retries/0`). A constant, not an option. The probe runs 4
times at most: once, then once after each of the 3 coder turns.

## Reports

Each script's events go to the server as the work's reports through the
existing line: `Report.events/3` makes the work's report (`Report.of/2`) once
per script and sends one `{:report, _}` per event, with the event under
`"event"`, to `Workflow.Server`, as `recorded/2` does. The last report is
unchanged: a devops work ends through `Run.land/3` and `unfly/2` like any
other, so `Report.ended/3` sends it (done, or stopped at resolve).

## One fix in Run

`Run.advance/2` performed any system step it found, including one the
template marks `stop: true`. No system step carried `stop` before; a refused
resolve does, and was performed again forever. A stopping step is no longer
performed: it is answered, and `started/2` / `system/1` stop the work as they
already do for any `stop: true` step.

## Where the plugin is

`Workflow.Devops.plugin/0`: `Workflow.Plugin.dir/0` when it has
`bin/resolve.exs`, else the folder `devops` beside it (the Code My Spec repo
ships `plugins/phoenix` and `plugins/devops` side by side).

## Callers checked

- `Run.kinds/0`: `Router` (`/work/run`, `/works/:id`), `Manager` tool schemas,
  `config_file_test`; the new kind only adds an entry.
- `Run.advance/2`: private, from `advanced/1`; the other templates have no
  system step with `stop`, so nothing they do changes.
- `Agents.skills/2`: private, from `Agents.run/2`; a step with no `:skills`
  finds none (`Skills.find(nil, _)` is `{:ok, []}`).
- `Manager.by_id/3`: private, from `hand_in`; only kind `devops` reaches the
  new clause.
- `Report.events/3`: new, called by `Workflow.Devops` alone.

No provision, deploy or go comes back: the work runs the plugin's scripts.

## Check

`test/workflow/loop_runs_a_devops_work_test.exs`: a fake plugin in tmp_dir
(`bin/resolve.exs`, shell probe/apply scripts that log their call, print two
events and exit 0 or 1), a fake agent and a fake server line, real git in
temporary repos, a works dir under tmp_dir. Six tests, all failing before the
fix: a hand-in refused naming each unresolvable line, with nothing run; a
work stopped at resolve naming the line; an apply work running apply then
probe per step and done; a check work running probes only; a failing probe
going to the coder with the provider's words and the devops skill 3 times,
then waiting on a person; every event line reaching the server as a report.
