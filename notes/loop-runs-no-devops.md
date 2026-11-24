# loop-runs-no-devops

The owner changed the design (2026-11-24): DevOps is one script plus evidence,
run by CI tooling on the CI runner, not by the loop. This cuts what
loop-runs-a-devops-work (76a600f, landed as 30fdde7) added.

## Cut

- `lib/workflow/devops.ex` (`Workflow.Devops`: `@retries`, the `resolve` and
  `probe` steps, the call to the plugin's `bin/resolve.exs`), and its
  `"devops"` entry in `Run`'s `@templates`, so `Run.kinds()` (and with it
  every `kind` enum in the manager's tools and the router's kind check) no
  longer offers `devops`.
- `action` and `environment`: from `@handed_in`, from the hand_in tool's
  schema (`story_properties/0`) and from its description.
- The manager's `by_id/3` clause for `kind: devops` and its refusals for a
  missing action, a missing environment and unresolvable devops.yml lines.
- `Workflow.Report.events/3`: its only caller was `Workflow.Devops` (grep:
  no other caller in lib or test).
- The `not is_map_key(step, :stop)` guard in `Run.advance/2`: only a devops
  step was ever a system step carrying `stop`. The other `stop: true` steps
  are not reached through `advance/2` as system steps: issue's conflicted
  promote goes to `fix` (coder), `Parts` sends a conflicted promote to `work`
  (coder) and a work with no parts stops at its first step `specify` (qa), and
  `copy-setup`/`merge-main` stops come from `owned/1`, before any template
  step. The guard did not exist before 76a600f and every other kind's tests
  pass without it.
- `Agents.skills` reading `step.agent[:skills]`: no template but Devops gives
  a step's agent `skills` (grep: issue, story, journey and Parts agents carry
  none).
- `test/workflow/loop_runs_a_devops_work_test.exs` (every test in it was of
  the devops kind) and `notes/loop-runs-a-devops-work.md`.

## Kept

Everything else exactly as it was, including CODEMYSPEC_PLUGIN for recipes and
agents, the plugin's MCP tools, reports (`recorded/2`, `ended/3` and the
reports a-work-reports-every-step-change added in the same merge), the `ci`
external step and evidence upload.

## Added

With no devops template, a hand-in of an unknown kind would reach
`Run.start/1`. The hand_in tool now refuses a kind not in `Run.kinds()` before
anything is started or recorded, naming the kind and the kinds there are.
`test/workflow/loop_runs_no_devops_test.exs` checks that refusal (no flight
file, no checkout, no commit, no agent) and that the tool schema has no
`devops` kind and no `action` or `environment`; it fails without the fix
(`devops` was in the kind enum).

## Counts

Lines of `.ex`/`.exs`:

| | before | after |
|---|---|---|
| lib | 7475 | 7170 |
| test | 13699 | 13453 |

Full suite, in four partitions (`--partitions 4`, the whole run passes the
120 s tool limit): 81 + 144 + 63 + 76 = 364 passed, 0 failed, 1 excluded
(`:real_just`). `mix compile --warnings-as-errors` is clean.
