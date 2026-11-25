defmodule Workflow.SignInTest do
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  @secrets ["access-one", "refresh-one", "access-two", "refresh-two", "secret-of-the-client"]

  setup do
    dir = Path.join(System.tmp_dir!(), "sign-in-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    server = %{
      "url" => "wss://loop.example/socket/websocket",
      "project_id" => "p",
      "state_dir" => dir
    }

    %{server: server}
  end

  # The server's side of the device grant, with no network: one pending poll,
  # then approval; a refresh hands out a second pair.
  defp fake(url, {kind, body}) do
    uri = URI.parse(url)
    assert {uri.scheme, uri.host} == {"https", "loop.example"}
    send(self(), {:asked, uri.path})

    case {uri.path, kind, body} do
      {"/oauth/register", :json, %{"grant_types" => grants}} ->
        assert Enum.sort(grants) ==
                 ["refresh_token", "urn:ietf:params:oauth:grant-type:device_code"]

        {:ok, 201, %{"client_id" => "client-1", "client_secret" => "secret-of-the-client"}}

      {"/oauth/device/code", :form,
       %{"client_id" => "client-1", "device_id" => <<_::binary-8, "-", _::binary-27>>}} ->
        {:ok, 200,
         %{
           "device_code" => "dev-1",
           "user_code" => "WXYZ-1234",
           "verification_uri" => "https://loop.example/device",
           "interval" => 5,
           "expires_in" => 600
         }}

      {"/oauth/token", :form,
       %{
         "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
         "device_code" => "dev-1",
         "client_id" => "client-1",
         "client_secret" => "secret-of-the-client"
       }} ->
        if Process.put(:polled, true),
          do:
            {:ok, 200,
             %{
               "access_token" => "access-one",
               "refresh_token" => "refresh-one",
               "expires_in" => 3600
             }},
          else: {:ok, 400, %{"error" => "authorization_pending"}}

      {"/oauth/token", :form,
       %{
         "grant_type" => "refresh_token",
         "refresh_token" => "refresh-one",
         "client_id" => "client-1",
         "client_secret" => "secret-of-the-client"
       }} ->
        {:ok, 200,
         %{"access_token" => "access-two", "refresh_token" => "refresh-two", "expires_in" => 3600}}
    end
  end

  test "sign-in writes the credential at 0600, an expiring token is refreshed before dialing, and no token is logged or printed",
       %{server: server} do
    http = &fake/2
    no_wait = fn _ms -> :ok end

    {out, log} =
      with_log(fn ->
        capture_io(fn ->
          assert :ok = Workflow.SignIn.sign_in(server, http: http, sleep: no_wait)
        end)
      end)

    assert out =~ "https://loop.example/device"
    assert out =~ "WXYZ-1234"
    assert_received {:asked, "/oauth/register"}

    hash = :crypto.hash(:sha256, "https://loop.example") |> Base.encode16(case: :lower)
    file = Path.join(server["state_dir"], "harness_oauth_#{hash}.json")
    assert (File.stat!(file).mode &&& 0o777) == 0o600

    held = file |> File.read!() |> Jason.decode!()

    assert held |> Map.keys() |> Enum.sort() ==
             ~w(access_token client_id client_secret expires_at refresh_token)

    assert %{
             "access_token" => "access-one",
             "refresh_token" => "refresh-one",
             "client_id" => "client-1",
             "client_secret" => "secret-of-the-client"
           } = held

    assert held["expires_at"] > System.system_time(:second) + 3000

    # Signing in again reuses the client the file holds.
    Process.delete(:polled)

    {again, log_again} =
      with_log(fn ->
        capture_io(fn ->
          assert :ok = Workflow.SignIn.sign_in(server, http: http, sleep: no_wait)
        end)
      end)

    refute_received {:asked, "/oauth/register"}

    # A token about to expire is refreshed before dialing, and the file rewritten.
    File.write!(file, Jason.encode!(%{held | "expires_at" => System.system_time(:second) + 5}))

    {dialed, log_dial} = with_log(fn -> Workflow.Server.dial(server, :header, http) end)

    assert dialed[:uri] == "wss://loop.example/socket/websocket"
    assert dialed[:headers] == [{"x-cms-token", "access-two"}]
    assert (File.stat!(file).mode &&& 0o777) == 0o600

    assert %{"access_token" => "access-two", "refresh_token" => "refresh-two"} =
             file |> File.read!() |> Jason.decode!()

    refute log_dial =~ "sign the harness in"

    for said <- [out, log, again, log_again, log_dial],
        secret <- @secrets,
        do: refute(said =~ secret, "#{inspect(secret)} was logged or printed")
  end
end
