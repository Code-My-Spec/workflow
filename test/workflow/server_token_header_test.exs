defmodule Workflow.ServerTokenHeaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # A made-up token, kept in a temporary state dir: never a real sign-in.
  @token "fake-access-token-for-the-test"

  setup do
    dir = Path.join(System.tmp_dir!(), "server-token-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    server = %{
      "url" => "wss://loop.example/socket/websocket",
      "project_id" => "p",
      "state_dir" => dir
    }

    hash = :crypto.hash(:sha256, "https://loop.example") |> Base.encode16(case: :lower)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "harness_oauth_#{hash}.json"),
      Jason.encode!(%{
        "access_token" => @token,
        "refresh_token" => "fake-refresh",
        "expires_at" => System.system_time(:second) + 3600
      })
    )

    %{server: server}
  end

  defp no_http(_url, _body), do: flunk("no request was expected")

  defp socket(server) do
    %{
      Slipstream.Socket.new()
      | channel_config: Slipstream.Configuration.validate!(uri: server["url"])
    }
    |> Slipstream.Socket.assign(server: server)
  end

  defp header(config), do: for({"x-cms-token", token} <- config.headers, do: token)
  defp in_url?(config), do: URI.to_string(config.uri) =~ @token

  defp disconnect(socket, reason) do
    {:ok, socket} = Workflow.Server.handle_disconnect(reason, socket)
    socket
  end

  @refused {:error, {:upgrade_failure, %{status_code: 403, resp_headers: [], reason: :x}}}

  test "socket-token-in-a-header: criterion 1 the connect URL carries no token and the x-cms-token header does",
       %{server: server} do
    {dial, log} = with_log(fn -> Workflow.Server.dial(server, :header, &no_http/2) end)

    assert dial[:uri] == "wss://loop.example/socket/websocket"
    assert dial[:headers] == [{"x-cms-token", @token}]
    refute log =~ @token

    # A reconnect dials the same way.
    socket = disconnect(socket(server), {:error, :closed})
    refute in_url?(socket.channel_config)
    assert header(socket.channel_config) == [@token]
  end

  test "socket-token-in-a-header: criterion 2 a 403 on the header connect falls back once to the query form, no other failure does",
       %{server: server} do
    {socket, log} = with_log(fn -> disconnect(socket(server), @refused) end)
    refute log =~ @token

    query = URI.decode_query(socket.channel_config.uri.query || "")
    assert query["token"] == @token
    assert header(socket.channel_config) == []

    # The query form refused too: back to the header, not the query form again.
    socket = disconnect(socket, @refused)
    refute in_url?(socket.channel_config)
    assert header(socket.channel_config) == [@token]

    # Any other failure of a header connect does not fall back.
    for reason <- [
          {:error, {:upgrade_failure, %{status_code: 401, resp_headers: [], reason: :x}}},
          {:error, {:upgrade_failure, %{status_code: 500, resp_headers: [], reason: :x}}},
          {:error, :econnrefused},
          :closed
        ] do
      socket = disconnect(socket(server), reason)
      refute in_url?(socket.channel_config), "fell back on #{inspect(reason)}"
      assert header(socket.channel_config) == [@token]
    end
  end
end
