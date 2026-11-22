# a-landed-work-resumes-waiting-on-ci: decision note

## Cause

The boot path ran certify again at the tree before it checked whether the work
had landed. `Workflow.Run.resume/0` calls `start/1` for each file in
`~/.workflow/works/`. A work waiting on ci has its `root` there, so it took
`start!/2` -> `owned!/2`, which began with `Checkout.afresh/2`. That function
drops the `certify` result kept at the current tree. With certify gone, the
issue template reads the work as being on `certify` again: certify comes before
promote, so promote's `promoted` at the same tree no longer counts. So certify
ran again ("[Workflow <id>] certify"). It merged the main copy's branch into
the copy, which moved the copy to a new tree with no results at all. At that
tree the branch has 0 commits of its own and no `promote` result, so
`Issue.status(fix)` sent it to the coder. The coder had nothing to commit. A
third send at the same tree stops the work (`wait/3`) and takes it out of
flight. That is the silent stall.

The ci wait itself was kept durably: `left/2` keeps a work on an external step
in flight. A second fault was hidden behind the first: `resume/0` took every
answer from `start/1` other than `"started"` out of flight, so a work that
resumed onto ci would have been dropped from flight anyway.

## Fix (lib/workflow/run.ex)

- `merged/1` is asked only on the path where a copy already exists (`start!/2`
  with a `root`: a resume, or a hand-in that carries its root). A copy cut just
  now in `copied/2` has not landed. `merged/1` checks two durable facts:
  - **Landed:** the copy is clean, has no commits of its own outside main
  (`commits: 0`, which skips merge commits), and `Checkout.landed?/3`, the same
  rule the manager uses (`branch_merged?` or `commits_merged?`), says yes when
  asked of the work's `repo`.
  - **The ci event:** it is read from the results file at the current tree by
  `Workflow.Parts.ci/2`, the same function the ci step uses.
- When the work has landed, `owned!/3` skips `afresh`, runs no system step and
  gives back no kept turn:
  - With no ci event, it waits at ci. The work is kept in flight, the log says
    "waiting on the event ci", and the work answers `"waiting"`.
  - With a green or flaky ci event, the work is done.
  - With a red ci event, the work goes to the coder with ci's note.
- `resume/0` keeps a work that answers `"waiting"` in flight, so a later
  `Run.event/3` finds it.
- A work that has not landed resumes exactly as before.

Callers checked: `owned!` (`start!/2` and `copied/2`), `start/1` (router,
manager, `flaky/2`, `resume/0`), `resume/0` (application boot). The new
`"waiting"` agent value reaches only `resume/0`, the manager's
`"on ci (external), waiting."` and the router's `agent` field.

## Check

`test/workflow/a_landed_work_resumes_waiting_on_ci_test.exs` uses real git in
a temporary directory, a stand-in `just` and agent, a works dir under tmp_dir
and a push remote that does not exist.

- **Criterion 1:** the work lands and waits at ci, then `resume/0` runs. The
  test shows no `just`, no certify or promote in the log, no agent turn, the
  work still in flight, look on `ci`, and the main copy's HEAD unchanged. A ci
  event afterwards finishes it.
- **Criterion 2:** with a red ci recorded, resume sends the work to fix with
  ci's note. With a green ci recorded, it is done. Neither runs `just` or moves
  the main copy.
- **Criterion 3:** the existing tests that resume a work that has not landed
  pass unchanged.

Both new tests fail on the old code (`refute log =~ "[Workflow i1] certify"`).

## Putting the two stuck carve-loop works back on their ci wait

The two works are evidence-puts-are-signed-without-a-type and
the-loop-installs-as-codemyspec. Do this after the fix ships, with nothing
re-landed. Run each step against that loop's own main copy (`<main>`), copy
(`<copy>` = `Checkout.root(<main>, <id>)`) and works dir.

1. Check that the copy still counts as landed. `git -C <copy> status
   --porcelain` must be empty. `git -C <copy> rev-list --count --no-merges
   <main branch>..HEAD` must be `0`. The merge of main that the second certify
   made does not count against it, and the coder in fix made no commit. If the
   copy is dirty, discard the changes (`git -C <copy> checkout -- . && git -C
   <copy> clean -fd`): they are not part of what landed. If a commit of its own
   exists, do not go on, because that work has not landed.
2. Make sure each work is in flight: `~/.workflow/works/<id>.json` must
   exist. If the third send stopped one, `wait/3` removed its file. Write it
   back as `{"kind":"issue","id":"<id>","repo":"<main>","root":"<copy>","own":true}`,
   adding `project` and `agents` if that loop's manager sets them. A file that
   is still there must have no `"turn"` key, or that key is ignored anyway once
   the work counts as landed.
3. Do not hand them in again through the manager. That path (`copied/2`) cuts
   or reuses the copy and does not ask whether the work landed. The kept
   `stopped` record needs no clearing: the restart's `Checkout.keep` clears it.
4. Restart the service on the new code. For each work, `resume/0` finds it
   landed: `commits_merged?` sees its `issue <id>: ...` commit merged into
   main, even though the branch tip moved. It finds no ci event at the copy's
   new tree, so it waits at ci and runs nothing. Its log says "waiting on the
   event ci". The ci event that comes next, for the commit it landed as, gets
   recorded at that tree and finishes the work. If ci already ran for that
   landing before the restart, its event was recorded at the old tree, so send
   it again (`POST /works/<id>/events` with name `ci` and the same verdict).
