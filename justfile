# The loop analyses this project by running `just <recipe> <dir>`, in whatever
# directory the work names as its project; it does not know mix or exunit.

export MIX_ENV := "test"

# Make a new copy of this project runnable, once, after the loop makes it.
copy-setup:
    mix deps.get

# Take down what this copy made for itself, before the loop removes it: this
# project makes nothing outside its own directory, so there is nothing to take down.
copy-teardown:

run dir:
    mix workflow.sarif "{{dir}}/exunit.sarif" -- mix test

certify dir:
    mix workflow.sarif "{{dir}}/compiler.sarif" -- mix compile --warnings-as-errors
    mix workflow.sarif "{{dir}}/exunit.sarif" -- mix test

# Build the prod release and its Homebrew tarball (on an Apple silicon Mac), then
# print the tarball's path and sha256 for packaging/codemyspec-loop.rb. `app` is
# the CodeMySpec app's repository: its plugins/phoenix and its interview skill go
# into the release as the default plugin and instructions that `workflow init` writes.
package app="":
    @test -n "{{app}}" || { echo "just package: give the app repository's path: just package <path>" >&2; exit 1; }
    @test -d "{{app}}" || { echo "just package: the app repository {{app}} does not exist" >&2; exit 1; }
    @test -f "{{app}}/plugins/phoenix/.claude-plugin/plugin.json" || { echo "just package: {{app}} has no plugin plugins/phoenix (with .claude-plugin/plugin.json)" >&2; exit 1; }
    @test -f "{{app}}/plugins/claude/directory/skills/interview/SKILL.md" || { echo "just package: {{app}} has no instructions file plugins/claude/directory/skills/interview/SKILL.md" >&2; exit 1; }
    MIX_ENV=prod mix deps.get
    MIX_ENV=prod mix release --overwrite
    rm -rf _build/prod/rel/workflow/plugin _build/prod/rel/workflow/instructions.md
    cp -R "{{app}}/plugins/phoenix" _build/prod/rel/workflow/plugin
    cp "{{app}}/plugins/claude/directory/skills/interview/SKILL.md" _build/prod/rel/workflow/instructions.md
    tar -C _build/prod/rel/workflow -czf _build/codemyspec-loop-darwin-arm64.tar.gz .
    @echo "tarball: {{justfile_directory()}}/_build/codemyspec-loop-darwin-arm64.tar.gz"
    @shasum -a 256 _build/codemyspec-loop-darwin-arm64.tar.gz | cut -d ' ' -f 1 | sed 's/^/sha256: /'
