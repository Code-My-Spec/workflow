# landed-means-merged: decision note

## The defect: confirmed

`commits_merged?/2` in `lib/workflow/checkout.ex` (lines 214-226 when the audit was
made) ran `git log -F --grep="<kind> <id>: " HEAD` and took any commit whose subject
starts with that prefix, other than `<kind> <id>: stopped...`, as proof the work landed.

What made the match too wide: it only asked whether a commit with that subject is
reachable from main's HEAD, not how it got there. An issue's file is committed
straight onto main, under the same prefix, when the issue is handed in
(`issue <id>: the issue as handed in`, `lib/workflow/manager.ex:745`). So that
commit alone made `landed?/3` true before any of the work's fix commits had reached
main.

## The fix

Commit `0f29cab` made the fix. A matching commit now counts only when it is off main's
first-parent line (`git rev-list --first-parent HEAD`), which means it came into main
through a merge and was not committed onto main itself. `branch_merged?/2` already
uses the same rule for a just-cut branch. Promote merges a work with `--no-ff`
(`lib/workflow/checkout.ex`, `git merge --no-ff --no-edit <commit>`), so a work's own
commits always arrive off the first-parent line. A story's
`story <id>: the story as handed in` commit, made on its branch and merged, still
counts as landed, as `manager-knows-what-landed` criterion 2 checks. The change adds
no option.

## The test

`test/workflow/manager_test.exs`, `landed-means-merged: criterion 1 ... criterion 2`.
The test makes a temporary git repo whose main has only
`issue i1: the issue as handed in`, with the fix commit on the unmerged `issue/i1`
branch. `Checkout.landed?(repo, "issue", "i1")` is false (criterion 1). After
`git merge --no-ff issue/i1` it is true (criterion 2).

Checked that it fails without the fix: with the `sha not in line` condition taken
out, the test fails at its first `refute` (line 1429). With the condition back, it
passes. No existing test was changed.
