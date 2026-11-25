# works-are-server-records: blocked

**Status: blocked.** The issue requires the loop side to follow the server
contract (endpoints, message names, record fields) in the doc "Works,
workflows and the queue", and forbids inventing one. That doc cannot be had,
and there is no contract Carve is building to that can be read in its place.

## Where it was looked for (2026-11-25)

- This checkout: the title appears only in `issues/works-are-server-records.yml`,
  `issues/parked-works-free-their-slot.yml` and
  `issues/the-cap-belongs-to-the-machine.yml` (all three cite it; none holds it).
- Every repo under `/Volumes/X10 Pro/github`, including `workflow`,
  `code_my_spec`, `code_my_spec-design`, `code-my-shit-docs`,
  `code_my_spec_content`, `userdocs` and `servers`: no file holds it.
- `code_my_spec` git history, every local and remote branch (`works-slice-1`,
  `origin/works-slice-1`, `origin/main`, `origin/dev`, `main-loop`,
  `origin/design-boards-works-pipeline-view`, and the rest), after a fetch: no
  file or commit names the doc or slice 2.
- The server code on those branches: no claim, hand-in-creates-a-record,
  claimed-by or work status contract exists yet, so the server cannot stand in
  for the doc.
- `~/Documents`, `~/Desktop`, `~/Downloads`, `~/.claude`: nothing.

## What was done

A first fix (55c8fef, 459cc09) built the loop side to a contract it wrote
itself (`notes/works_contract.md`: `hand_in`, `claim`, a pushed `work`,
`claimed`, `work_status`, `claimed_by`, statuses queued/running/parked/done/
stopped). Review refused it as an invented contract, and it was reverted
(9577c2c, 5950b36). The code itself was sound and can be brought back with
`git revert 5950b36 9577c2c`, then renamed to the real contract.

## To unblock

Put the doc in this checkout (or say where it lives), or give the contract
Carve's server side implements: the hand-in, claim and recover-claimed calls or
channel events, their payloads, and the work record's fields and status values.
Then the loop side and its stubbed-server tests are rebuilt to match it exactly.
