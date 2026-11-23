# story-ids-are-required

Stories, their rules and their scenarios carry ids; a story hand-in requires
them. Built on main as it stands: story-hand-in-pins-a-commit has not landed
(no `at` field exists yet), so "by id" here is the manager's hand-in of a story
by its id alone. When `at` lands, its by-id path should keep calling the same
check (`Workflow.StoryFile.ids_refused/1`) on the story read at that commit.

## Where it lives

- Parsed: `Workflow.StoryFile.recorded/2` (top-level `id:` of a story-shaped
  file, one with no `kind:`, becomes `story_id`; `read_rules/1` reads a rule's
  and a scenario's `id:` whether it comes first or after `rule:` / `happy:` /
  `fails:`).
- Validated: `Workflow.StoryFile.ids_refused/1`, called by the manager's
  `by_id/2` for a story (`ids_checked/1`).
- Generated: `Workflow.StoryFile.with_ids/1` (and `new_id/1`), called by
  `by_id/2` for a story that carries its text, before `started/1` records it.
- Recorded: `Workflow.StoryFile.yaml/1` writes the ids.
- Briefs: `Workflow.Agents.own/1` lists `Workflow.StoryFile.labelled/1`.

Only stories in the story's shape (with `title`, `story` or `rules`) are
checked; one handed in the old way (text and criteria) has no rules or
scenarios and is not. Reading (status, listing, look, `recorded/2`,
`criteria/1`) never refuses.

## Story fields as built

In the file (`stories/<id>.yml`, the file name still the human handle):

    id: k3f9a2qw
    title: ...
    story: >
      ...
    rules:
      - rule: ...
        id: 7hd2k3pz
        scenarios:
          - happy: ...
            id: x9m4c8tb
          - fails: ...
            id: r5w2n7qa
    questions: ...

The loop writes `id:` after `rule:` / `happy:` / `fails:`; it reads either
order, so `- id: ...` first (as the chat agent may write it) reads the same.
An id that starts with a digit is written quoted (`id: "9tzuwevj"`), as other
values YAML could read as numbers are; plain or quoted reads the same.

On the manager's `hand_in` tool (all optional; generated when absent on a
hand-in that carries its text):

- `story_id` (string): the story's own id. In the work and in what
  `recorded/2` returns, the story's id is `story_id`; `id` stays the handle.
- `rules[].id` (string): the rule's id.
- `rules[].scenarios[].id` (string): the scenario's id; a scenario is now
  1 to 2 properties (`id` with `happy` or `fails`).

An id is 8 characters from `23456789abcdefghjkmnpqrstuvwxyz`, random, unique
within the story. Ids handed in are kept as given.

## Refusal wording

One answer, naming every problem:

    Refused: story <handle> cannot be handed in, <problems>. The story, each rule and each scenario needs an id of its own (`id:`), 8 characters from 23456789abcdefghjkmnpqrstuvwxyz. Nothing was started.

where `<problems>` is one or both of, joined by `; and `:

- `these have no id: <places>`, places joined by `; `, each one of
  `the story`, `rule <n> ("<rule text>")`,
  `scenario <m> of rule <n> ("<scenario text>")` (positions from 1);
- `these ids repeat: <id> (<count> times)`, sorted, joined by `, `.

For example:

    Refused: story s1 cannot be handed in, these have no id: the story; rule 1 ("Only an owner may invite."); scenario 2 of rule 1 ("A member tries to invite and is refused."). The story, each rule and each scenario needs an id of its own (`id:`), 8 characters from 23456789abcdefghjkmnpqrstuvwxyz. Nothing was started.

## Briefs

The agents' first message lists each criterion followed by its ids, and the
header names the story's id:

    This work's own criteria (story k3f9a2qw), and no other story's:
    1. Only an owner may invite. An owner invites and the invite is sent. (rule 7hd2k3pz, scenario x9m4c8tb)

A story without ids is listed exactly as before.

## Tests

`test/workflow/story_ids_test.exs`, one per criterion, in temporary git repos
with a fake agent. Criteria 1 to 4 fail with the lib changes reverted; criterion
5 (id-less files still read) passes either way, as it guards against a check
being put on the read path. Fixtures that hand in stories in
`manager_test.exs` and `router_test.exs` gained ids, nothing else.
