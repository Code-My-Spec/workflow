# a-work-that-ends-sends-a-last-report: decision note

## Cause

A report is sent only when a step result is recorded
(`Checkout.record/4` -> `Report.recorded/2`), and at each join
(`Server.handle_join/3` resends `Report.in_flight/0`, read from the works
dir). No report was queued: a push that failed was logged and dropped, and
the works file was the only thing that let a report be sent again. A work
that ends has its works file removed (`Run.land/1`) and records nothing more.
So its newest report on the server stayed at the step it was on ("ci" for a
work waiting on its event), and no later join could correct it.

## Every way a work ends

All of them go through `Run.land/1`, which removed the works file, and now
through `Run.unfly/2`:

- **The manager's stop** (`Manager.stop/1` -> `Run.cancel/1`): status
  "stopped", at the step it was on.
- **A manager release by hand**: there is no separate release tool. The
  manager releases a work waiting at ci with the same stop (`Parts.ci/2` doc:
  "the manager releases the work by hand"). A work stopped while it is on ci
  has landed, so its last report says "released", at "ci"
  (`Report.ended/3`).
- **A ci event that finishes it** (`Run.event/3` -> `watch` -> `system/1`
  -> `left(work, nil)`, green, flaky or skipped): "done", at the last step
  ("ci"). The same `left/2` and `at_ci(nil, _)` path covers a work that
  resumes and is found done.
- **The loop stops it** (`stop!/3`: a step nobody can act on, an agent that
  cannot run, turns that went down, handoffs spent, a dirty tree, a run that
  ended in error twice; and `copied/2` when copy-setup fails): "stopped", at
  the step it stopped at.
- **The boot path drops it** (`resume/0`, a work still in flight that
  `start/1` neither started nor left waiting): "stopped".
- `Checkout.remove/4` and `Checkout.disown/4` take the copy away. They do
  not end a work on their own: `cancel/1` calls `remove`, after the report;
  `advanced/1` and `at_ci/2` call `disown` before `left/2`. A done work's copy
  may therefore be gone when its report is made, so `Report.ended/3` reads it
  from the repository it was cut from, which shares the copy's results.

Left without a last report, since they have not ended: a work waiting on its
owner (`wait/3`, `left/2` on an owner's step, `system/1` with no agent), which
`decide` or a new hand-in starts again; a work stopped for good while a turn
ran (`turned/6`, `stop/3` on a cancelled work), whose report `cancel/1`
already sent; and `copied/2`'s hand-in left with nobody to run it.

## Exactly one

`unfly/2` sends the report, then removes the file, under a `:global` lock on
the work's id, and only while the file is there. The first path to end the
work sends it; a second (a stop after the ci event, a turn ending after a
stop, the boot path after a work that finished inside `start/1`) finds no file
and sends nothing.

## Kept while the line is down

Reusing what exists: `Server.handle_info({:report, _}, _)` pushes, and the
join resends. A last report whose push fails (status done, stopped or
released) is kept in the line's state, the newest for each work, and sent
once at the next join with the reports in flight. Any other report is still
dropped, as before. The rule that a server crashing on a report gets no more
(`no_reports`) is unchanged: its clause comes first, so kept reports are
dropped for it too. What is kept lives in the line's process, as a join's
resend does. A restart loses it, as it loses the old line's state.

## Callers checked

`Run.cancel/1`: `Manager.stop/1` only. `Run.land/1`, `land/2`, now `land/3`
with an optional `ended`, and `unfly/2` are private to `Run`. The new
`Report.ended/3` is called by `Run.unfly/2` alone. `Server.handle_info/2` and
`handle_join/3` are called by Slipstream, `report_test.exs` and
`server_test.exs`; their existing tests pass unchanged (a failed non-last
report still leaves the socket as it was).

## Check

`test/workflow/a_work_that_ends_sends_a_last_report_test.exs`: real git in a
temporary directory, a works dir under tmp_dir, a stand-in `just`, agent and
server line. It covers four cases: a stop ("stopped" at its step), a release
of a work waiting at ci ("released" at "ci"), a green ci event ("done" at
"ci", and no second report from a stop after it), and a line down (kept,
pushed once on the next join, not again at the join after). All four fail on
the code before the fix. That the report goes before the file is removed is
the order in `unfly/2`. A test cannot observe it without racing the removal.
