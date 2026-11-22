defmodule Workflow.VersionTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  test "version-from-the-tag: the version comes from the git tag, falls back without one, and router.ex reports it" do
    # `git describe --tags` at tag v3.0.0 gives 3.0.0.
    assert Workflow.MixProject.version_from({"v3.0.0\n", 0}) == "3.0.0"

    # No tag (git fails) or no git (the command cannot run) gives the fallback.
    fallback = Workflow.MixProject.fallback_version()
    assert {:ok, _} = Version.parse(fallback)

    assert Workflow.MixProject.version_from(
             {"fatal: No names found, cannot describe anything.\n", 128}
           ) == fallback

    assert Workflow.MixProject.version_from(:error) == fallback

    # The version router.ex reports is the application's version.
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> Workflow.Router.call(Workflow.Router.init([]))

    assert %{"result" => %{"serverInfo" => %{"version" => reported}}} =
             Jason.decode!(conn.resp_body)

    assert reported == to_string(Application.spec(:workflow, :vsn))
  end
end
