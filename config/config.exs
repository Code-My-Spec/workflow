import Config

# Run on its own, it serves. Under test it does not: the suite runs beside a
# served instance. As a dependency this file is not read, and it serves nothing.
config :workflow, port: if(config_env() == :test, do: nil, else: 4010)

# Under test, works in flight are kept nowhere a served instance would resume them.
if config_env() == :test,
  do:
    config(:workflow,
      works_dir: Path.join(System.tmp_dir!(), "workflow-test-works"),
      # Each project alone under test: never the real ~/.workflow/machine.
      machine_dir: false
    )
