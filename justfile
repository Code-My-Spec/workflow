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
# print the tarball's path and sha256 for packaging/codemyspec-loop.rb.
package:
    MIX_ENV=prod mix deps.get
    MIX_ENV=prod mix release --overwrite
    tar -C _build/prod/rel/workflow -czf _build/codemyspec-loop-darwin-arm64.tar.gz .
    @echo "tarball: {{justfile_directory()}}/_build/codemyspec-loop-darwin-arm64.tar.gz"
    @shasum -a 256 _build/codemyspec-loop-darwin-arm64.tar.gz | cut -d ' ' -f 1 | sed 's/^/sha256: /'
