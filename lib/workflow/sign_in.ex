defmodule Workflow.SignIn do
  @moduledoc """
  The loop's own sign-in to its server, by the OAuth device grant, and the
  credential it keeps: `harness_oauth_<sha256 of the server's base URL>.json`
  in the state dir (the server's `"state_dir"`, else `$CMS_STATE_DIR`, else
  `~/.codemyspec`), at mode 0600, with `access_token`, `refresh_token`,
  `expires_at`, `client_id` and `client_secret`.

  `workflow sign-in` (the release) or `mix workflow.sign_in` signs in to the
  server `config.json` names: it registers a client once, prints where to
  approve and the code to enter, and waits for the approval. `token/2` gives
  the loop a token to dial with, refreshing one about to expire. No token or
  secret is ever logged or printed.

  Every request goes through an `http` function,
  `(url, {:json | :form, map}) -> {:ok, status, body} | {:error, reason}`.
  """
  require Logger

  @device_grant "urn:ietf:params:oauth:grant-type:device_code"
  # A token with less than this many seconds left is refreshed before dialing.
  @margin 30

  @type http :: (String.t(), {:json | :form, map()} ->
                   {:ok, non_neg_integer(), term()} | {:error, term()})

  @doc "Signs in to the server `config.json` names; halts with status 1 if it cannot."
  @spec main() :: :ok
  def main do
    {:ok, _} = Application.ensure_all_started([:ssl, :req])

    result =
      with :ok <- Workflow.ConfigFile.load() do
        case Application.get_env(:workflow, :server) do
          %{"url" => "" <> _} = server -> sign_in(server)
          _none -> {:error, "#{Workflow.ConfigFile.path()} names no \"server\" with a \"url\""}
        end
      end

    with {:error, why} <- result do
      IO.puts(:stderr, "Sign-in failed: #{why}")
      System.halt(1)
    end
  end

  @doc """
  Signs in to `server` by the device grant and saves the credential. Options:
  `:http` (see the moduledoc) and `:sleep`, given the milliseconds to wait
  between polls.
  """
  @spec sign_in(map(), keyword()) :: :ok | {:error, String.t()}
  def sign_in(%{"url" => url} = server, opts \\ []) do
    http = Keyword.get(opts, :http, &post/2)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    base = base(url)
    {:ok, host} = :inet.gethostname()

    with {:ok, client} <- client(server, base, http),
         {:ok, %{"device_code" => "" <> device, "user_code" => "" <> code} = grant} <-
           request(http, base <> "/oauth/device/code",
             form: Map.put(Map.take(client, ["client_id"]), "device_id", device_id(host))
           ) do
      IO.puts(
        "Open #{grant["verification_uri"] || grant["verification_url"]} and enter the code #{code}"
      )

      wait = (grant["interval"] || 5) * 1000

      case poll(base, Map.put(client, "device_code", device), wait, http, sleep) do
        {:ok, tokens} ->
          save(server, Map.merge(client, credential(tokens, %{})))
          IO.puts("Signed in to #{base}.")
          :ok

        refused ->
          {:error, why(refused)}
      end
    else
      refused -> {:error, why(refused)}
    end
  end

  @doc """
  An unexpired access token for `server`, or nil. One about to expire is
  refreshed with its refresh token first, and the file rewritten.
  """
  @spec token(map(), http()) :: String.t() | nil
  def token(server, http \\ &post/2) do
    now = System.system_time(:second)

    case read(server) do
      %{"access_token" => "" <> token, "expires_at" => at}
      when is_integer(at) and at > now + @margin ->
        token

      %{"refresh_token" => "" <> _} = held ->
        refresh(server, held, http)

      _none ->
        nil
    end
  end

  # The server takes only a UUID as a device id; this one is the same for a host every time.
  defp device_id(host) do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12, _::binary>> =
      Base.encode16(:crypto.hash(:sha256, to_string(host)), case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  @doc "The server's base URL: http(s), no path."
  @spec base(String.t()) :: String.t()
  def base(url) do
    uri = URI.parse(url)
    scheme = if uri.scheme in ["wss", "https"], do: "https", else: "http"
    to_string(%URI{scheme: scheme, host: uri.host, port: uri.port})
  end

  @doc "The real `http` function, by Req."
  def post(url, {kind, body}) do
    case Req.post(url, [{kind, body}, retry: false]) do
      {:ok, %Req.Response{status: status, body: reply}} -> {:ok, status, reply}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp client(server, base, http) do
    case read(server) do
      %{"client_id" => "" <> id, "client_secret" => "" <> secret} ->
        {:ok, %{"client_id" => id, "client_secret" => secret}}

      _none ->
        registration = %{
          "client_name" => "CodeMySpec loop",
          "grant_types" => [@device_grant, "refresh_token"],
          "token_endpoint_auth_method" => "client_secret_post"
        }

        with {:ok, %{"client_id" => "" <> id, "client_secret" => "" <> secret}} <-
               request(http, base <> "/oauth/register", json: registration) do
          {:ok, %{"client_id" => id, "client_secret" => secret}}
        end
    end
  end

  # Polled until the user approves or denies, slower when the server asks.
  defp poll(base, form, wait, http, sleep) do
    sleep.(wait)

    case request(http, base <> "/oauth/token", form: Map.put(form, "grant_type", @device_grant)) do
      {:ok, %{"access_token" => "" <> _} = tokens} -> {:ok, tokens}
      {:error, _status, "authorization_pending"} -> poll(base, form, wait, http, sleep)
      {:error, _status, "slow_down"} -> poll(base, form, wait + 5000, http, sleep)
      other -> other
    end
  end

  defp refresh(server, held, http) do
    base = base(server["url"])

    form =
      held
      |> Map.take(["refresh_token", "client_id", "client_secret"])
      |> Map.put("grant_type", "refresh_token")

    case request(http, base <> "/oauth/token", form: form) do
      {:ok, %{"access_token" => "" <> token} = tokens} ->
        save(server, Map.merge(held, credential(tokens, held)))
        Logger.info("[Workflow.SignIn] refreshed the sign-in for #{base}")
        token

      refused ->
        Logger.warning(
          "[Workflow.SignIn] cannot refresh the sign-in for #{base}: #{why(refused)}"
        )

        nil
    end
  end

  # A 2xx body as `{:ok, body}`; anything else as `{:error, status, error code}`,
  # so no body (which may hold a token) is ever carried into a message.
  defp request(http, url, [{kind, body}]) do
    case http.(url, {kind, body}) do
      {:ok, status, %{} = reply} when status in 200..299 -> {:ok, reply}
      {:ok, status, %{"error" => "" <> error}} -> {:error, status, error}
      {:ok, status, _reply} -> {:error, status, "no error given"}
      {:error, why} -> {:error, nil, "#{url} unreachable: #{inspect(why)}"}
    end
  end

  defp why({:error, nil, why}), do: why
  defp why({:error, status, error}), do: "the server answered #{status} (#{error})"
  defp why({:error, "" <> why}), do: why
  defp why(_unexpected), do: "the server's answer was not understood"

  defp credential(tokens, held) do
    %{
      "access_token" => tokens["access_token"],
      "refresh_token" => tokens["refresh_token"] || held["refresh_token"],
      "expires_at" => System.system_time(:second) + (tokens["expires_in"] || 3600)
    }
  end

  defp read(server) do
    with {:ok, body} <- File.read(path(server)),
         {:ok, %{} = held} <- Jason.decode(body) do
      held
    else
      _none -> nil
    end
  end

  # Written whole at 0600 and moved into place, so no reader sees half a file.
  defp save(server, credential) do
    file = path(server)
    tmp = file <> ".tmp"
    File.mkdir_p!(Path.dirname(file))
    File.write!(tmp, "")
    File.chmod!(tmp, 0o600)
    File.write!(tmp, Jason.encode!(credential))
    File.rename!(tmp, file)
  end

  defp path(%{"url" => url} = server) do
    dir = server["state_dir"] || System.get_env("CMS_STATE_DIR") || "~/.codemyspec"
    hash = :crypto.hash(:sha256, base(url)) |> Base.encode16(case: :lower)
    Path.expand(Path.join(dir, "harness_oauth_#{hash}.json"))
  end
end
