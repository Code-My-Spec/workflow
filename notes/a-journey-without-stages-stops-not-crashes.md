# a-journey-without-stages-stops-not-crashes

Seen live: journey 1fbd8e34-af4d-4391-af91-2854ede435f7, handed in again
without its stages, had no `:stages` in its snapshot; the loop crashed in
`Workflow.Parts.next_unnamed/2` with `length(nil)`, and every `look` at it
crashed too, so the manager could neither see it nor stop it.

## Where a list was assumed

- `Workflow.Parts.next_unnamed/2`: `Map.fetch!` then `length(parts)`.
- `Workflow.Parts.specify_note/4`: `Map.fetch!` then `Enum.at(parts, n - 1)`,
  reached first by the `%{named: []}` clause of `status/5` (the crash a
  work with nothing named yet hits: Enumerable not implemented for nil).
- `Workflow.Parts.observe/4` copies `work[key]` into the snapshot as it is
  (nil when absent); `Workflow.Story.observe/2` takes
  `Workflow.StoryFile.criteria/1`, which falls back to `work["criteria"]`.
- `Workflow.Run.look/1` (the manager's `look`, the router's and the report's)
  and `Workflow.Run.step/start/resume` all reach the above through
  `Workflow.current/2` and the template's `status/2`.
- The manager's `with_stages/1` already refused a journey hand-in without
  stages (pattern `[_ | _]`); a story had no such check, in `by_id/3` for a
  carried story or in `pinned/3` for one read from its file.
- `Workflow.StoryFile.labelled/1` guards with `is_list/1`: not a crash.

## The fix

- `Workflow.Parts.status/5` checks the parts list first: with none (missing
  or empty, and nothing named yet) the step is `stop: true` with the note
  "this journey has no stages; hand it in again with its stages" ("this story
  has no criteria; hand it in again with its criteria"). `Run.started/2` and
  `system/1` already stop a `stop: true` step, keeping the note where `look`
  shows it as `stopped`. An empty list with parts already named walks on as
  before (story_test's "an empty criteria list leaves nothing left to name").
- The manager's `with_criteria/1` refuses a story hand-in whose criteria
  (carried, from rules and scenarios, or read from its file by id or at a
  sha) are missing or empty, before anything is recorded, queued or started.

Callers of `Parts.status/5`: `Workflow.Story.status/2`, `Workflow.Journey`'s
`walk/2`; the issue template does not use it.
