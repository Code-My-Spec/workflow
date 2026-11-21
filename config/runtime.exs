import Config

# The release has no source to edit: the port is set from the environment.
if port = System.get_env("WORKFLOW_PORT"), do: config(:workflow, port: String.to_integer(port))
