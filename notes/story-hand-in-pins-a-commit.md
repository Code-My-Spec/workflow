# story-hand-in-pins-a-commit: decision note

## Where story paths are built and read (confirmed, then changed)

- `Workflow.StoryFile`: `paths/1` gives `<project>/.code_my_spec/stories/<id>.yml`, then
  `<project>/stories/<id>.yml`. `located/2` picks the first that exists in a root, and the old
  one when neither exists. `path/2` (written only for a hand-in that carries its own text),
  `recorded/2` (read from a folder) and the new `at/3` (read with `git show <sha>:<path>`)
  all use them.
- Callers: `Run.story_file/1` passes the work's root to `path/2`. In the manager, `stop` passes
  the repo to `path/2`, and the journey `by_id` uses `recorded/2` and `located/2`. The story
  `by_id` uses `at/3`.
- `Workflow.Report.unstarted/1` reads journeys from `.code_my_spec/stories/` first, then
  from `stories/`, and reads each id once per project.
- Briefs: in `Workflow.Parts.own/1` (QA, coder, reviewer), the rule now names both
  `.code_my_spec/stories/*.yml` and `stories/*.yml` and says never to change a story file.
  The manager's brief carries the `at`, the open-questions/`go: true` and the queued-newer-sha
  rules. `Workflow.Agents.message/4` gives a pinned work's agents
  `git show <sha>:<path>` and, for a queued work, the difference and its diff.

## How a story handed in by its id alone is built

1. `Checkout.pinned/2` fetches the main copy (`git fetch --all`, only when it has a remote)
   and resolves `at`, or HEAD when there is no `at`, to a full sha.
2. `StoryFile.at/3` reads the story at that sha, trying the new path first and then the old.
3. Open `questions:` refuse the hand-in, unless it has `go: true`.
4. The work is marked `recorded` (so no story file is written or committed) and carries
   `story_at` (the sha) and `story_path`. These are kept beside its results, as
   `Checkout.kept/2` shows.
5. Another work for the same story id, in flight or queued, at the same sha: refused as a
   duplicate. At a newer sha (`git merge-base --is-ancestor`): a new work
   `<id>-<7-char sha>` with `behind`, `story_id`, `story_from` (the older sha) and
   `story_diff` (`git diff <old>..<new> -- <story path>`). `Run.queue/1` keeps it in
   `<works_dir>/queued/<id>.json`. When the work it is behind lands (done, waiting on its
   owner, or stopped), `Run.land/1` starts it, and so does `Run.resume/0` after a restart. At
   a sha that is not newer: refused.

A hand-in that carries its own text (text/criteria/stages or title/story/rules/questions)
works as it did before: its file is written and committed as
"<kind> <id>: the <kind> as handed in". `at` and `go` are ignored there.

## The manager's hand_in tool, for a story, exactly as built

`required: ["kind", "id"]`. Every other field is optional.

| field | type | meaning |
|---|---|---|
| `kind` | string, enum `issue`, `journey`, `story` | `story` here |
| `id` | string, plain name (letters, digits, dashes) | the story id; its file is `.code_my_spec/stories/<id>.yml`, else `stories/<id>.yml` |
| `at` | string | the commit sha to read the file at (4-40 hex chars); default the main copy's HEAD. Used only when handed in by id alone |
| `go` | boolean | `true` only when the person said go despite open questions. Used only when handed in by id alone |
| `skills` | object, role to array of strings | more skill folders for this work only |
| `text` | string | old shape: hand in with text (writes and commits the file) |
| `criteria` | array of strings | old shape |
| `stages` | array of strings | a journey's |
| `title`, `workflow`, `story` | string | the story's shape, handed in whole (writes and commits the file) |
| `rules` | array of `{rule: string, scenarios: [{happy\|fails: string}]}` | the story's shape |
| `questions` | array of strings | the story's shape |

What each answer says (`{:ok, text}`):

- Started: `<id>: on <step> (<actor>), started. Its log: <path>` (or `not started`, or
  `<id>: done.`), as before.
- Queued: `<id>-<short sha>: story <id> at <sha>, queued behind <first id>: it starts once
  <first id> is done or stopped, and builds the difference from <old sha>.`
- `at` not sha-shaped: `Refused: at "<at>" is not a commit sha. Nothing was started.`
- No such commit: `Refused: there is no commit <at> in the main copy, fetched just now.
  Nothing was started.`
- No `at` and no HEAD: `Refused: "<repo>" has no commit at its HEAD, so no story is recorded
  there. Nothing was started.`
- No file at that commit: `Refused: no story <id> is recorded at commit <sha>: neither
  <project>/.code_my_spec/stories/<id>.yml nor <project>/stories/<id>.yml is in the main copy
  at that commit. Commit it first, or hand it in whole. Nothing was started.`
- Open questions: `Refused: story <id> at <sha> has open questions: <q1>; <q2>. Settle them in
  the story file, or hand it in with go: true when the person said to go ahead despite them.
  Nothing was started.`
- Same sha again: `Refused: story <id> at <sha> is already handed in, as <work id>: a
  duplicate. Nothing was started.`
- Older or unrelated sha: `Refused: story <id> is in flight at <sha in flight>, and <sha> is not
  newer. Nothing was started.`
- Unchanged: the refusals for the cap, for a work stopped for good, for bad skills, and for an
  id that is not a plain name.

## Tests

`test/workflow/story_hand_in_pins_a_commit_test.exs` has one test per criterion. Each runs in a
temporary repo with a bare origin, a chat clone that pushes story commits, and a fake agent.
With `lib/` reverted all 6 fail, and with the fix all 6 pass. The full suite passes (330).
Nothing was tagged, published or pushed.
