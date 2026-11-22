# small-audit-fixes-in-the-loop: decision note

Callers were grepped in `lib` and `test`. This repository has no `scripts` folder.

## (a) Results file updated with no lock: true, fixed

Every writer of `<git common dir>/workflow/<id>.json` (`cancel`, `record`, `keep`,
`afresh`, `stop`, `say`, `reject`, `answered`, `heard` in `lib/workflow/checkout.ex`)
read the file, changed the map and wrote it back with no lock. Each work has its own
file, so the updates that collide are two made close together to one work's file, for
example the run's `record` and the owner's POST /work/say. One of the two was lost.
The new test showed this on the first try: two `say`s at once kept only `["b1"]`.

The fix is one private `update/3` in `Checkout`. It reads, changes and writes the file
inside `:global.trans({{Checkout, :results, path}, self()}, ...)`, the same kind of lock
ci-last uses, keyed by the file. It writes only when there is a change, and it returns
what it found, which `heard` needs. All nine writers go through it. No process or
option was added.

Test: `test/workflow/results_file_lock_test.exs` criterion 1 makes two `say`s at the
same moment, 30 times, in a temporary repo, and checks that `heard` returns both. It
fails without the lock.

## (b) Checkout.commit_file/4 unused: true, deleted

No caller in `lib` or `test`; every call site uses `commit_files/3`. It had no tests
of its own, so none were removed. Deleted from `lib/workflow/checkout.ex`.

## (c) Three `defp now`: true, they were identical, now one

`checkout.ex`, `run.ex` and `report.ex` each had
`defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()`. The one in `Checkout`
is now public (`Checkout.now/0`). `Run` and `Report` already alias `Checkout`, so they
call it. Their copies are deleted.

Test: criterion 3 in the same test file calls `Checkout.now/0` and parses it as ISO 8601
UTC. It fails while `now` is private.

## Line counts (before -> after)

- lib/workflow/checkout.ex: 1240 -> 1237
- lib/workflow/run.ex: 963 -> 962
- lib/workflow/report.ex: 197 -> 195
- test/workflow/results_file_lock_test.exs: 0 -> 35 (new)
- notes/small-audit-fixes-in-the-loop.md: new

`just certify` passed: compile with warnings as errors and the full `mix test`, both
exit 0 with no results.
