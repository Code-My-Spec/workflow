# run-tests-wait-for-the-run: decision note

## Cause

The cause is in the tests, not in `lib/`, so `lib/` is unchanged. `Workflow.Run.start/1`
and `resume/0` answer once a watch task is started; the agent stand-in is called later,
from the turns. Tests gave that background work a fixed receive deadline or a sleep.
`settled/0` (moved to `test/support/settled.exs`) waits on processes with the test in
`$callers`; the turns run under `spawn_monitor`, which drops `$callers`, so `idle/0`
also waits on every process the loop started (matched by module, as `Workflow.Tellings`
does) and on the registered deployers. `deployed/0` waits on the deployers only.

## Tests changed

- run_test: provider errors twice (parked); provider errors once (retried);
  agents-commit-no-ignored-files (:915); no-stalls c4 turns end done; no-stalls c4
  waiting on its owner; no-stalls c4 resume; stop-ends-the-turn-first c1-2;
  deploy-after-landing c1, c2, c3, c5; ci-gates-uat c1 (no ci recipe), c2, c3 (red twice),
  c3 (known red), c3 (no one work), c4; ci-retries-with-a-retry-recipe c3;
  system-steps-outlive-their-caller; copy-lifecycle-recipes c3 (copy-setup fails);
  messages c5; manager-sees-outcome c1; `checkout()` on_exit deploy poll (`deployed/0`).
- router_test (`wait_out/1`): go-needs-the-owners-word c3, c4;
  local-api-refuses-foreign-hosts; handing in a work that names a repo.
- checkout_test (`told/0`): flake-rerun c1, c2; build-cop c1, c3, c4; loop-failures.
- ci_retries_test (`told/0`): c1-3, c4, retry-is-told-the-first-run.
- main_copy_follows_remote_test: c3 conflict.
- restart_survives_an_interrupted_copy_test (`landed/1`): c1+3, c2+3.
- a_refused_flake_is_not_lost_test (`notice/1`).
- manager_test: manager c3.

checkout_test, ci_retries_test and main_copy_follows_remote_test got a
`Workflow.Tellings.quiet` setup, so `idle/0` never waits on work left by an earlier test.

## Waits left alone (each waits on something other than a run ending)

- Agent stand-ins held until the test lets them go: manager_test `{:agent ...}` and
  stop-a-work's DOWN on the agent, hand_in_at_the_cap:76, issue_hand_in_again:80,
  journey_hand_in:99, skills_test:118, router_test:1247/1261, a_refused_flake 107/153,
  run_test stop-ends-the-turn-first `{:turn}`.
- Recipes or runs held mid-way: ci_checkouts_pruned:92, ci_blame_per_landing:89 and its
  marks poll at :93, restart_survives `wait_for(started)` and its `:killed` DOWN,
  run_test deploy-after-landing c4, system-steps `{:answered}` / `{:certifying}`.
- A held manager turn: manager_test `{:run, ...}` with `manager_run("never")`.
- A clock: a_refused_flake:109 `sleep(1_100)`, hand-ins are kept to the second.
- Synchronous calls: `{:alloy_opts}` in agents, plugin, skills; `{:tools}` after the tell.
- Not a run: report_test (reports from `Checkout.record`).

## 1. Repeats (`--repeat-until-failure`, 0 failures each)

- run_test.exs:915 agents-commit-no-ignored-files, at tree ee9ee1f: 101 runs.
- First round, the 11 run_test/router_test tests above: 26 + 31 + 43 = 100 runs.
- Second round, 51 tests (the changed run_test, main_copy_follows_remote_test and
  manager_test tests, and all of checkout_test, ci_retries_test,
  restart_survives_an_interrupted_copy_test, a_refused_flake_is_not_lost_test): 101 runs.
- After the Tellings.quiet setup, checkout_test, ci_retries_test,
  main_copy_follows_remote_test: 51 runs.

## 2. Full suite

- At tree ee9ee1f (HEAD before this note): 3 of 3 passed, 376 passed, 1 excluded
  (seeds 303439, 827407, 610978).
- At c20c81c: 4 of 4 passed, 374 passed, including seed 73149, which had failed before the
  quiet setup. `just certify` exit 0.

## 3. Each changed test fails when what it guards is broken

Each break made alone in `lib/`, the tests run, the break undone.

Unwanted message or push does happen (`idle()` then `refute_received`):

- Deploy with no deploy key -> deploy-after-landing c2 fails at `refute_received` worktree add -b.
- A provision's own landing runs ci and deploys -> deploy-after-landing c3 fails at `refute_received` worktree add.
- ci deploys whatever its result -> ci-gates-uat c3 red twice (`refute_received` worktree add -b),
  c3 known red (`refute_received` manager_told), c3 no one work (`refute_received` manager_told again) fail.
- A deploy hands in a second provision -> ci-gates-uat c4 fails at `refute_received` worktree add -b.
- A flake told twice, 100 ms apart -> checkout_test flake-rerun c2 "Told once" fails in `told/0`.
- A refused push told twice, 100 ms apart -> build-cop c3 "Nothing retries on a timer" fails.
- A refused push pushed again on a timer until it goes -> build-cop c4 "Nothing pushes again"
  fails: `idle()` waits on the retrying push, test timed out.
- A recipe failing twice told as a flake -> flake-rerun c1, ci_retries c4 fail at `told() == []`.

Wanted behaviour removed:

- The provision not handed in (deploy never runs) -> deploy-after-landing c1, c2; ci-gates c1,
  c2, c4; ci-retries c3 fail at `assert_received` worktree add -b.
- The manager not told a work landed, stopped or waits -> deploy-after-landing c5,
  copy-lifecycle c3, messages c5, manager-sees-outcome c1, manager c3 fail at
  `assert_received`; a-refused-flake fails in `notice/1`.
- A ci red not told -> ci-gates c3 (no one work) fails at `assert_received` manager_told.
- No report to the server -> ci-retries c3 fails at `assert_received` report.
- A finished work kept in flight -> system-steps-outlive-their-caller fails (works file
  still there); both restart tests fail in `landed/1`.
- A flake not told -> flake-rerun c2, ci_retries c1-3 fail in `told/0`.
- A refused push not told -> build-cop c1, c3, loop-failures fail in `told`.
- A conflict not told -> main-copy-follows-remote c3 fails in `told`.
- A landing pushes nothing -> build-cop c4 fails at the remote dev assert.
- An agent error not retried -> both provider tests fail at `assert_received`.
- The second note (ignored paths) dropped -> :915 fails at `assert second =~ "tmp/scratch.txt"`.
- The works file not removed when a work ends -> no-stalls c4 (both) and router repo-checkout
  (`settled`/`wait_out` then refute) fail.
- resume starts nothing -> the resume test fails at `assert_received {:ran, "fix"}`.
- cancel ends the turn after the worktree goes -> stop-ends-the-turn-first fails at `assert_received {:removed, ...}`.
- /work/go starts nothing -> go c3, go c4, local-api fail in `wait_out/1` then `assert_received`.

With a 600 ms delay before each agent turn, the old :915 failed as in the fault
(`assert_receive` after 100ms) and the new one passed.

Not breakable: the deploy wait in `checkout()`'s on_exit (`deployed/0`) has no assertion.
