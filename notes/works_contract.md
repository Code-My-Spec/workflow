# Works are server records: the contract (provisional)

Slice 2 of "Works, workflows and the queue". The doc says only: hand-in creates
a work on the server, with its workflow and the thing it works on, before the
loop sees it; loop reports update that record; a work shows in the pipeline from
the moment it is handed in, and a loop restart loses nothing. This file is the
wire contract both sides build to. The loop side is `Workflow.Works`; the server
side is built to this file afterwards. It is provisional: change it here first.

Everything travels on the loop's existing channel, `loop:<project_id>`, joined
with the loop's own sign-in. Nothing here carries a credential.

## The record

One per work, keyed by the work's id (a plain name, unique in the project).

| field        | type           | written by | meaning |
|--------------|----------------|------------|---------|
| `id`         | string         | server, at creation | the work's id |
| `kind`       | string         | server, at creation | `issue`, `story` or `journey` |
| `workflow`   | string         | server, at creation | the workflow it runs (today the kind's own) |
| `subject`    | object         | server, at creation | the thing it works on, as handed in: `text`, `criteria`, `title`, `stages`, `story`, `rules`, ... |
| `status`     | string         | server at creation (`queued`), then the loop | `queued`, `running`, `parked`, `done` or `stopped` |
| `step`       | string or null | the loop | the step the work is on (null until it starts) |
| `note`       | string or null | the loop | the last report's one-line note |
| `claimed_by` | string or null | server, on a claim | the loop that runs it: its `harness_id`, else its project's loop |
| `updated_at` | string         | server | when the record last changed (ISO 8601) |

Statuses: `queued` (handed in, not started), `running` (on a step), `parked`
(waiting on a person), `done` (finished, landed), `stopped` (given up on, or
stopped for good). `done` and `stopped` are final.

## Messages

All on `loop:<project_id>`. "Call" means a push the loop waits on a reply for.

1. **`hand_in`**, a call from the loop, when its manager hands a work in:
   `{kind, id, workflow, subject}`. The server creates the record (`queued`)
   and replies ok `{work: record}`. A refusal is error `{reason}`. The loop then
   claims it (2). The server sends no `work` push for a record made this way.
2. **`claim`**, a call from the loop: `{work: id}`. The server sets
   `claimed_by` and replies ok `{work: record}`. A record claimed by another
   loop, final, or unknown is refused with error `{reason}`; the loop then runs
   nothing of it. Claiming a record this loop already holds is ok.
3. **`work`**, a push from the server, for a record created on the server (the
   pipeline, the chat agent): the record itself. The loop claims it (2) and runs
   it.
4. **`report`**, a push from the loop, unchanged from slice 0, plus
   `work_status`. Sent at hand-in, at every step change and as the work ends.
   `work` names the record, `step` and `note` are copied onto it, and
   `work_status` (one of the statuses above) becomes its `status`. The report's
   own `status` keeps its slice-0 words for the pipeline view.
5. **`claimed`**, a call from the loop at its first join after starting: `{}`.
   The server replies ok `{works: [record]}`, every record this loop has claimed
   that is not final. The loop runs each one with no work of its own for that id
   on from the step the record shows: a `queued` one is queued again, a
   `running` one is started and given its `step`'s turn back. A `parked` one
   waits on its person, as it does before a restart.

## Who holds what

The server holds the work: what it is, what it works on, its status and step.
The loop holds only how to run it here: its repository, project directory and
agents come from the loop's own settings (`config.json`'s manager), not from the
record. A loop that has lost its works directory gets back every claimed work
from (5).
