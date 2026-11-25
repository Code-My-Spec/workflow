# the-cap-belongs-to-the-machine

The cap on works in flight is the machine's, and its slots are shared by every
project the machine runs (`Workflow.Machine`).

## Where the machine's cap is read from

Each project still names its own cap where it did: `"manager" -> "cap"` in its
`config.json` (default 3). At each hand-in the project's loop writes itself into
the machine's directory, `~/.workflow/machine/` (the `:machine_dir` setting):
one file per works directory, `{"works_dir": ..., "cap": ...}`, named by a hash
of that directory.

## How a machine's projects agree on it

- The machine's cap is the smallest cap any of its projects names.
- The works holding a slot on the machine are every works file
  (`<works_dir>/*.json`) of every project written there, but a parked one
  (`Workflow.Run.running/1`). A queued work is not in flight, as before.
- A parked work resumes only into a slot free on the machine (`Workflow.Run.slot?/0`).
  Its loop looks for one when a slot frees in its own project; a slot freed in
  another project is found at its loop's next free slot or hand-in.
- A hand-in that would go past the machine's cap is refused, as at a project's
  cap before: "Refused: N works are in flight, at the cap of C". Once a work
  anywhere on the machine ends, its slot is free to any project's next hand-in.
- A project whose works directory is gone is no longer one of the machine's;
  delete its file under `~/.workflow/machine/` to forget it sooner.
- A machine running one project counts only that project, under its own cap:
  the behaviour before this change.

Under test `:machine_dir` is `false` (config/config.exs): each project is alone,
and nothing is written to the real `~/.workflow`. The tests in
`test/workflow/the_cap_belongs_to_the_machine_test.exs` give the machine a
folder of their own.

Not covered: two hand-ins made at the same moment in two projects' loops are
not serialised, as two at once in one project's were not before.
