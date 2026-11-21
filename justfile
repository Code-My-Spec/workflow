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
