# queue-done-whens-proven: decision note

## Already proven on main: no code change, no new test

Each of the queue epic's four done-whens already has a test on main that
proves it, so this issue adds none. Every one of these tests works in its
ExUnit tmp dir with a fake `:agents_run`. Where the machine matters,
`:machine_dir` points under the tmp dir. Where a server is configured, it is
only a URL that is never reached. No test touches the real `~/.workflow` or
`.git/workflow`. All 13 tests in the four files pass on main
(`mix test test/workflow/the_queue_test.exs
test/workflow/works_wait_on_works_test.exs
test/workflow/parked_works_free_their_slot_test.exs
test/workflow/the_cap_belongs_to_the_machine_test.exs`).

## 1. Slice 3, the queue

> With five works running, a sixth hand-in is queued, and it starts on its own
> when one of the five finishes.

`test/workflow/the_queue_test.exs`, "the-queue: criteria 1 and 2, with five
works running at a cap of five a sixth hand-in is queued, not refused, and
starts on its own when one of the five finishes". Five works hold the five
slots. The sixth is answered "queued", is in `Workflow.Run.queued_works/0`
and has no works file. When `w1` lands and parks at ci, `w6` starts with no
further call, and the queue is left empty.

## 2. Slice 4, works wait on works

> A work that names a prerequisite starts once that prerequisite has landed.

`test/workflow/works_wait_on_works_test.exs`, "works-wait-on-works: criteria 1
and 2, a work handed in after X holds no slot while X has not landed, and
starts on its own once X lands". With slots free (1 of 3 in use), `y` is
handed in `after: ["x"]` and is held in the queue, even through
`next_in_slot/0`. Once `x` lands, `y` starts.

## 3. Slice 5, parked works free their slot

> A parked work, waiting on a person or on CI, frees its slot.

Two tests in `test/workflow/parked_works_free_their_slot_test.exs`, both at a
cap of 1:

- Waiting on a person: "parked-works-free-their-slot: criterion 1 - with the
  cap full and one work waiting on a person, a newly handed-in work still
  starts". `person1` is stopped, "waiting on its owner", and `held2` then
  starts.
- Waiting on CI: "parked-works-free-their-slot: criterion 2 - a work waiting
  at the ci step holds no slot: another work starts in its place". `ci1`
  lands and waits at ci (`step: "ci", actor: :external`), and `held2` then
  starts.

## 4. Slice 6, the cap belongs to the machine

> With two projects on one machine, no more works run at once than the cap,
> and queued works start oldest hand-in first.

Two tests together prove this one:

- The cap: `test/workflow/the_cap_belongs_to_the_machine_test.exs`,
  "the-cap-belongs-to-the-machine: criteria 1 and 2, two projects on one
  machine with a cap of 2 never run more than 2 works between them, and a
  freed slot takes the other's waiting work". Projects `a` and `b` each run
  one work. A third hand-in in either project is queued "at the cap of 2".
  When `a1` is stopped, `b2` takes the slot, and the machine is full again.
- Oldest hand-in first: `test/workflow/the_queue_test.exs`, "the-queue:
  criterion 3, queued works from two projects on one machine start in hand-in
  order". At a cap of 1, `b1` is queued before `a2`. The slot frees in `a`,
  but `a2` does not take it. `b1` starts first, then `a2`. That note
  (`notes/machine-queue-is-oldest-first.md`) records that this test fails
  when the cross-project check in `next_queued/0` is removed.
