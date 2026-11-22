# the-loop-publishes-as-codemyspec: decision note

The brew formula is now `codemyspec`. The command it installs is still `workflow`.

## Files changed or renamed

- `packaging/codemyspec-loop.rb` renamed to `packaging/codemyspec.rb`: `class Codemyspec`,
  log and error log at `var/"log/codemyspec.log"`. The `__VERSION__`, `__URL__` and
  `__SHA256__` placeholders and the `bin/"workflow"` wrapper are unchanged.
- `justfile`: `package` builds `_build/codemyspec-darwin-arm64.tar.gz`. `release` sets the
  notes to "codemyspec <version> for macOS on Apple silicon" and the url to
  `https://github.com/Code-My-Spec/workflow/releases/download/v<version>/codemyspec-darwin-arm64.tar.gz`.
  It fills `packaging/codemyspec.rb` into the tap's `Formula/codemyspec.rb` and adds it, runs
  `git rm -q --ignore-unmatch Formula/codemyspec-loop.rb`, and then commits
  "codemyspec <version>". The skip-when-unchanged check comes after the removal, so the
  commit both adds the new formula and removes the old one.
- `lib/workflow/init.ex`: prints `brew services start codemyspec`.
- `README.md`: `brew install codemyspec`, `brew services start codemyspec`. This file never
  had a stop line or a log path, and none were added.
- `packaging/README.md`: formula path, tarball name, `brew install codemyspec`,
  `brew services start/stop codemyspec`, log at `$(brew --prefix)/var/log/codemyspec.log`.
- Tests renamed to the new names, with no assertion weakened: `test/workflow/init_test.exs`,
  `package_carries_the_plugin_test.exs`, `packaged_defaults_survive_an_upgrade_test.exs`
  (Cellar path is now `Cellar/codemyspec/...`), `packaging_test.exs`, `release_recipe_test.exs`.
  The upgrade test's code (`Workflow.ConfigFile`, `Workflow.Init`) reads the release root from
  `RELEASE_ROOT` and does not use the formula name, so it needed no change.
- `test/workflow/release_recipe_test.exs`: two new tests run `just release 3.0.4` with every
  outside call faked. gh records its calls and succeeds, except `release view`, which fails.
  mix lays out a release. `git clone` makes a local tap, with or without
  `Formula/codemyspec-loop.rb`. `git push` records the tap's HEAD commit (subject,
  name-status, the `Formula/codemyspec.rb` it holds) and pushes nothing. They check:
  - the gh upload names `codemyspec-darwin-arm64.tar.gz`;
  - the notes say "codemyspec 3.0.4";
  - the commit is "codemyspec 3.0.4";
  - it adds `Formula/codemyspec.rb` (class Codemyspec, version 3.0.4, the new url);
  - in the same commit it deletes `Formula/codemyspec-loop.rb`;
  - with a tap that has no old formula, the release still commits.
  Both tests fail against the old justfile and formula (checked), and both pass now.
  Nothing is published, tagged or pushed. No real tap is touched.

## Grep

`grep -rnI -e codemyspec-loop -e CodemyspecLoop` over the repository, excluding `.git`,
`issues/`, `notes/`, `_build/` and `deps/`, finds only:

- `justfile:67`: `git -C "$tmp/tap" rm -q --ignore-unmatch Formula/codemyspec-loop.rb`
- `test/workflow/release_recipe_test.exs` lines 149, 179, 190, 196, 204: the fake tap's old
  formula, and the assertions that it is removed or never mentioned.

Item 2 and the release-test rule require these: the recipe has to name the old file to
remove it, and the test has to name it to show the removal. Every other mention is gone.
As written, this conflicts with item 6 and criterion 5. I kept the literal name instead of
splitting the string to hide it from grep.

`just certify` passes.
