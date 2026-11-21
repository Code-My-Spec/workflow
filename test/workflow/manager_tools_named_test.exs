defmodule Workflow.ManagerToolsNamedTest do
  use ExUnit.Case, async: true

  @router Path.expand("../../lib/workflow/router.ex", __DIR__)
  @readme Path.expand("../../README.md", __DIR__)

  @manager_tools ["hand_in", "record", "decide", "look", "tell", "stop"]

  test "the router comment and the README name all six manager tools on /mcp/manager" do
    assert File.read!(@router) =~
             "# The manager's own tools (hand_in, record, decide, look, tell, stop)"

    [_, endpoint] = Regex.run(~r/^- `POST \/mcp\/manager`(.*?)^\S/ms, File.read!(@readme))
    for tool <- @manager_tools ++ ["say", "inbox"], do: assert(endpoint =~ "`#{tool}`", tool)
  end
end
