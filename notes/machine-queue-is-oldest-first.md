# machine-queue-is-oldest-first: decision note

## Already true on main: no code change, no new test

Across the projects on one machine, queued works already start first-in
first-out by hand-in time, as the-queue's review said.

- `enqueue/1` (`lib/workflow/run.ex`) stamps each queued work with
  `handed_in_at`, the time it was handed in.
- When a slot frees, `next_queued/0` (`lib/workflow/run.ex`) starts the top of
  this project's queue only if no other project on the machine
  (`Workflow.Machine.others/0`) has a queued, unheld work with an earlier
  `handed_in_at` (`longest/1`). So the project that freed the slot, or whose
  loop looks first, does not take it ahead of an older hand-in elsewhere. The
  project holding the oldest work takes it at its loop's next look for a slot.

## The test that shows it

`test/workflow/the_queue_test.exs`, "the-queue: criterion 3, queued works from
two projects on one machine start in hand-in order". It is the test this issue
asks for, so none was added:

- Two projects, `a` and `b`, in the test's tmp dir share one machine
  (`:machine_dir` under the tmp dir, never the real `~/.workflow`) at a cap of 1.
  The agents run is a fake, and the server is configured but never reached.
- `a1` runs. `b1` is queued, then `a2`.
- `a1` finishes, so the slot frees in project `a`, and `a`'s loop looks first.
  `a2` does not start. Then `b`'s loop takes the slot for `b1`, and `a2` still
  waits. Once `b1` finishes, `a2` starts.

I checked that it fails without the rule. With `Workflow.Machine.others()`
replaced by `[]` in `next_queued/0`, the test fails at line 191:
`assert_receive {:fix, "b1", b1}` gets `{:fix, "a2", ...}` because `a` took
the freed slot for its own later hand-in. With the code as it is, the test
passes.
