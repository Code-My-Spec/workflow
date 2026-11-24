# resume-skips-a-work-of-an-unknown-kind

Seen live on the MetricFlow loop: a works file of kind "provision" (a kind cut
by the-loop-does-no-deploys) made `Workflow.Run.resume/0` crash with
`nil.steps/0`, and the crash killed resume for every other work on the loop.

## The defect, confirmed

The new test reproduces the crash, unfixed: `resume/0` calls `start/1`, which
calls `start!/2` and then `owned!/3` and `system_step/1`. That calls
`Workflow.current(nil, ...)`, which raises `UndefinedFunctionError nil.steps/0`
in `resume/0`'s own process. The comprehension stops, so no work after it is
resumed.

## Every @templates[kind] lookup on the resume and boot path

The boot path is `Workflow.Application` (`application.ex:77`, the only caller of
`resume/0` outside tests), which calls `Task.start(&Workflow.Run.resume/0)`.
From `resume/0`:

- `resume/0`: the fix. It looks up `@templates` once for each works file. A
  work whose kind has none is not started. Its works file is neither changed nor
  deleted (it is never passed to `start/1` or `unfly/2`), and one warning
  `[Workflow <id>] not resumed: its kind "<kind>" has no template` is logged.
  Every other work goes through `start/1` as before.
- `start!/2` (a work with a repo and no root) goes to `copied/2` and then
  `owned!/3`. It no longer gets an unknown kind from resume.
- `merged/1` (`@templates[kind].steps()`, when the work has a repo and has
  landed) no longer gets an unknown kind from resume.
- `owned!/3` goes to `kept_turn/2` (`@templates[kind].steps()`, when a turn was
  kept in flight) and to `system_step/1` (`@templates[kind]` into
  `Workflow.current/2`, the crash seen live). Neither gets an unknown kind from
  resume any more.
- `advanced/1` and `to_coder/2` (`@templates[kind]`), reached from `owned!/3`
  and `started/2`, are behind the same check.
- `look/1` (`@templates[kind]`) is not on the resume path. Its callers already
  refuse an unknown kind: the router checks `kind in Workflow.Run.kinds()`
  before it calls `look/1`, and the manager's tools take `kind` as an enum of
  `Run.kinds()`.
- `release/1` (from `resume/0`, `unfly/2` and `queue/1`) starts a queued work in
  a `Task` of its own, so an unknown queued kind crashes only that task and
  never resume. A queued work behind an unknown-kind work stays queued, because
  that work is still in flight. Neither is changed: the issue names only
  resume.

No function's signature or answer changed. The only caller of `resume/0` is
`application.ex:77`, plus the tests that call it directly.

## The check

`test/workflow/resume_skips_a_work_of_an_unknown_kind_test.exs` uses temporary
git repos, a temporary works dir and a fake agent. It writes a "provision" works
file beside an "issue" one and runs `resume/0`. The test shows that resume
returns `:ok`, the issue's agent is given its `fix` step, the provision file is
byte for byte as written, and one warning names `a-provision` and `provision`.
Without the fix it fails with the live crash, `nil.steps/0`.
