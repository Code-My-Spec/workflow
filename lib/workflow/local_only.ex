defmodule Workflow.LocalOnly do
  @moduledoc """
  The loop's HTTP API as it is served: `Workflow.Router`, for a request whose Host
  is 127.0.0.1 or localhost (any port). Any other Host is refused with 403 and
  nothing it asked for is done, so a web page that rebinds its own name to
  127.0.0.1 cannot reach the API.
  """
  @behaviour Plug
  import Plug.Conn

  @hosts ["127.0.0.1", "localhost"]

  @impl true
  def init(opts), do: Workflow.Router.init(opts)

  @impl true
  def call(%Plug.Conn{host: host} = conn, opts) do
    if String.downcase(host) in @hosts do
      Workflow.Router.call(conn, opts)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "only a Host of 127.0.0.1 or localhost is served"}))
      |> halt()
    end
  end
end
