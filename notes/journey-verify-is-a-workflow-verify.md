# journey-verify-is-a-workflow-verify: decision note

## Main, checked first

On main the journey workflow did not run its walk as a verify:
`priv/workflows/journey.json` (the file the journey workflow is read from; there
is no `workflows/journey.yml`) named no `verify`, so a journey was done once its
`ci` step was.

## What the journey's walk is

A journey's walk is its test: the plugin's QA journey skill has one test,
`test/journeys/<journey>_test.exs`, walk the whole journey stage by stage. The
loop runs it with the project's `just run`, the `run` step
(`Workflow.Checkout.test/3`). So the walk needs no new step: the file names `run`
as its verify.

## The fix

`priv/workflows/journey.json` now has `"verify": "run"`. A journey's steps end
with the system step `verify` (`Workflow.Workflows.steps!/1`), which runs the walk
at the work's final tree (`Workflow.Template.perform/4`). A walk that passes ends
the work as done. A walk that fails stops it, with the note "The verify failed: "
and the walk's output (`Workflow.Template.status/3`), as a failed verify does.

## The tests

`test/workflow/a_journey_is_done_only_when_its_walk_passes_test.exs`, criteria 1
and 2. Each starts a journey with every step done, a fake `just` as its walk, and
no real git, browser or app. It checks that the next step is `verify`, performs
it, and reads the journey's state from the result. Without the fix both fail
because there is no verify step and the journey is already done.

Two existing tests listed the journey's steps, so they now include the verify at
the end: `journey_test.exs` (step order) and `workflows_are_data_test.exs` (the
file's steps, plus the verify the file names). Neither was weakened.
