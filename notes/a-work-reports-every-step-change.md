# a-work-reports-every-step-change: decision note

## Cause

Three things, found in the code:

1. **Reports were sent only when a result was recorded**
   (`Checkout.record/4` -> `Report.recorded/2`) and at each join. A hand-in
   records nothing (`Run.prepared/1` only keeps the work), and neither does
   entering a step. An issue's first step is the coder's `fix`, and its first
   record is when that turn ends. So a work handed in and at work on fix (like
   hosted-dev-pulls-from-ghcr, devops-server-tool-hetzner and
   devops-email-tool-resend) sent nothing until its coder finished.
2. **A report whose push failed was dropped** (`Server.kept/2` kept only last
   reports: done, stopped, released). Any change made while the line was down
   was lost until the next join.
3. **Reports were made in a `Task.start` each, unordered.** Two changes close
   together could reach the line in either order, so an older picture could
   arrive last, even after a work's last report.

The red ci path itself does report: `Run.event/3` -> `record_event/4` ->
`Checkout.record/4`, and `Run.look/1` reads the work at fix then. In this
checkout a red ci event with the line up already pushed a report at fix. So
new-user-registers-reliably's report was most likely lost to (2), dropped
while the line was down, or overtaken by an older report under (3).

## Where a work's step or status changes

- Hand-in and boot (`Manager` -> `Run.start/1`, `Run.resume/0` ->
  `start/1`): all reach `owned!/3`, after `prepared/1`. **Now reports**
  ("handed in"). A copy not made yet is reported once its copy-setup is done:
  before then there is no checkout to read a picture from.
- Entering a system step (`advance/2`, before `perform`): **now reports**.
- A step's result (`advance/2`, `turned!/6`, decisions in `prepared/1`):
  reported by `Checkout.record/4`, as before.
- Entering an agent's step (`turn/5`): **now reports**.
- An event (`Run.event/3`, the server channel's `"event"` and
  `POST /works/:id/events`): reported by `Checkout.record/4`. The run after it
  (`watch` -> `system/1`) reports the step it enters, so a red ci reports fix
  twice: on the record and on entering fix.
- A wait on the owner (`wait/3`): **now reports** after `Checkout.stop/4`,
  since it does not end the work.
- A stop and the end (`stop!/3`, `cancel/1`, `left/2`, `copied/2`,
  `resume/0`): the one last report from `unfly/2`
  (a-work-that-ends-sends-a-last-report), unchanged. No new report goes
  before it on these paths, so there is still exactly one per ending.
- `left/2` on an external step (waiting on ci): the picture is the one the
  promote result already reported, so nothing new is sent.

## The change

- `Run.report/1`, private, calls `Report.recorded/2` at the four places
  above.
- `Report.recorded/2` makes the report in a task it waits on, as `ended/3`
  does, so reports leave in the order the work changed. It still never fails
  a step: `safely/1` logs, and a task that outlives 60s is killed.
- `Server`: a report whose push fails, and has a status, is kept: the newest
  per work, in the order works last changed (`:kept`, which replaces
  `:ended`). At a join the kept reports go first, once, then every work in
  flight read fresh, so each work's newest picture is the last sent. The
  `no_reports` clause still comes first, so an old server that crashed on a
  report gets none, kept or not. The rejoin backoff is untouched. A report
  with no status (`report_test`'s bare `%{"work" => "i1"}`) is not kept, as
  before.

## Callers checked

`Report.recorded/2`: `Checkout.record/4` and now `Run.report/1`.
`Checkout.record/4`: in `lib`, `Run` alone (results, decisions, events,
`by`), and tests. Each caller now waits on the report being made when
the line is registered. With no line (most tests) it is the same no-op.
`Server.handle_info({:report, _}, _)` and `handle_join/3`: Slipstream,
`report_test.exs`, `server_test.exs`, and
`a_work_that_ends_sends_a_last_report_test.exs`. All pass unchanged.

## Check

`test/workflow/a_work_reports_every_step_change_test.exs`: real git in
tmp_dir, a works dir under tmp_dir, a stand-in `just`, agent and server line.

- criterion 1, a hand-in pushes a report at fix while the coder's turn is
  held. **Fails without the fix.**
- criterion 3, a red ci event pushes a report at fix. **Passes without the
  fix**: as above, the event's record already reports it with the line up.
  It is kept as the check that the path stays reported.
- criterion 4, reports pushed with the line down are kept and sent once at
  the next join, w1's newest (fix) last. **Fails without the fix.**

Criterion 2 is covered by the places listed above, by criteria 1 and 3, and
by the last-report tests.
