# recipes-know-the-plugin: decision note

Callers were grepped in `lib` and `test` (`grep -rn '"just"' lib`, then each caller
of the functions that reach those calls).

## Where Checkout runs a `just` recipe

Every `just` call in `lib` is in `lib/workflow/checkout.ex`. Three of them run a recipe:

- `cut/5`: `just copy-setup`. Reached from `Checkout.own/5`, called by `Run` (`lib/workflow/run.ex`).
- `teardown/3`: `just copy-teardown`. Reached from `Checkout.disown/4` and
  `Checkout.remove/4`, called by `Run`.
- `run_recipe/8`: every other recipe, through `analyse/5` and `rerun/6`:
  - `run`: `Checkout.test/2`, called by `Parts` (`lib/workflow/parts.ex`).
  - `certify`: `Checkout.certify/3`, called by `Issue` and `Parts`.
  - `demo`: `Checkout.demo/2`, called by `Journey`.
  - `ci`: `Checkout.ci/3`, called by `Run`.
  - `retry`: `rerun/6`, when a ci fails and the project has a `retry` recipe.

The other `just` calls are lookups and are left as they are: `just --show demo` in
`demo/2`, `just --show ci` in `ci/3`, and `just --show <name>` in `recipe?/3`.
`lib/workflow/application.ex` only names `just` as a needed tool.

## The fix

One private `recipe_env/1` in `Checkout` takes the call's env and puts
`{"CODEMYSPEC_PLUGIN", <Workflow.Plugin.dir/0, expanded>}` in front of it. With no
plugin configured it returns the call's env unchanged, so the variable is not set.
The three recipe calls above pass `env: recipe_env(...)`: copy-setup and
copy-teardown with `[]`, `run_recipe` with the env it was already given, which is
kept. `Checkout.cmd/4` and its scrub are unchanged. CODEMYSPEC_PLUGIN does not match
the scrubbed names. No option was added.

## Test

`test/workflow/recipes_know_the_plugin_test.exs` builds a temporary git repo whose
copy-setup, copy-teardown, run, certify and demo recipes each write
`${CODEMYSPEC_PLUGIN-unset}` into a file, and certify also writes `${EXTRA-unset}`.
It runs `own`, `test`, `analyse(..., "certify", [{"EXTRA", "given"}])`, `demo` and
`disown` for real, once with a plugin configured and once with none. With a plugin,
every file holds the plugin's absolute path, and certify's also holds `given`. With
none, every file holds `unset`. Without the fix, the first half fails because every
file says `unset`.

ci and retry go through the same `run_recipe/8` call as run and certify. The test
does not drive `Checkout.ci/3`, because a green ci also uploads evidence.
