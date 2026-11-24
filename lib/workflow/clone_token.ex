defmodule Workflow.CloneToken do
  @moduledoc """
  The git credential for a repo the server hosts. Before a clone, fetch or push
  the loop asks its server, `POST <server>/api/repo/clone_token` with its own
  sign-in token (`Workflow.SignIn.token/2`) and `project_id`. A 200 with
  `token`, `expires_at` and `clone_url` means the server hosts the repo; any
  other answer means it does not (the customer's own GitHub), and git runs as it
  always has. With no server configured nothing is asked.

  The answer, hosted or not, is kept in memory only for one token lifetime: a
  token until `@margin` seconds before its `expires_at`, a refusal for
  `@refused_for` seconds. The token reaches git as `http.<host>.extraHeader`
  through `GIT_CONFIG_*` variables of that one command: never in a remote URL,
  never in a file, never logged.
  """

  # A token with less than this many seconds left is asked for afresh.
  @margin 300
  # How long a refusal (not hosted) is kept before the server is asked again.
  @refused_for 3600

  @doc """
  What a git command that reaches the remote needs: `{:ok, nil}` for today's
  path (no server, or not hosted), `{:ok, %{env: env, clone_url: url}}` for a
  hosted repo, or `{:error, line}` when a hosted repo's token cannot be had.
  """
  @spec auth() ::
          {:ok, nil | %{env: [{String.t(), String.t()}], clone_url: String.t()}}
          | {:error, String.t()}
  def auth do
    case Application.get_env(:workflow, :server) do
      %{"url" => "" <> url, "project_id" => project} = server when project not in [nil, ""] ->
        key = {__MODULE__, Workflow.SignIn.base(url), to_string(project)}
        now = System.system_time(:second)

        case :persistent_term.get(key, nil) do
          {:hosted, token, expires_at, clone_url} when expires_at - @margin > now ->
            {:ok, %{env: env(token, clone_url), clone_url: clone_url}}

          {:refused, until} when until > now ->
            {:ok, nil}

          held ->
            asked(server, key, now, match?({:hosted, _, _, _}, held))
        end

      _none ->
        {:ok, nil}
    end
  end

  defp asked(server, {_, base, project} = key, now, hosted_before?) do
    case request(server, base, project) do
      {:ok, token, expires_at, clone_url} ->
        :persistent_term.put(key, {:hosted, token, expires_at, clone_url})
        {:ok, %{env: env(token, clone_url), clone_url: clone_url}}

      {:refused, _why} ->
        :persistent_term.put(key, {:refused, now + @refused_for})
        {:ok, nil}

      # A repo known to be hosted whose token cannot be had fails its git step;
      # one never answered for keeps today's path and is asked again next time.
      {:error, why} when hosted_before? ->
        {:error, "No clone token for project #{project} from #{base}: #{why}"}

      {:error, _why} ->
        {:ok, nil}
    end
  end

  defp request(server, base, project) do
    with "" <> bearer <- Workflow.SignIn.token(server) || {:error, "the loop is not signed in"},
         {:ok, %Req.Response{status: 200, body: %{} = body}} <-
           Req.post(base <> "/api/repo/clone_token",
             json: %{"project_id" => project},
             headers: [{"authorization", "Bearer " <> bearer}],
             retry: false
           ),
         %{"token" => "" <> token, "clone_url" => "" <> clone_url} <- body,
         {:ok, expires_at} <- expires_at(body["expires_at"]) do
      {:ok, token, expires_at, clone_url}
    else
      {:ok, %Req.Response{status: status}} when status in 400..499 ->
        {:refused, "the server answered #{status}"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "the server answered #{status}"}

      {:error, %{__exception__: true} = exception} ->
        {:error, "the server is unreachable (#{Exception.message(exception)})"}

      {:error, "" <> why} ->
        {:error, why}

      _unexpected ->
        {:error, "the server's answer was not understood"}
    end
  end

  defp expires_at(at) when is_integer(at), do: {:ok, at}

  defp expires_at("" <> at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _offset} -> {:ok, DateTime.to_unix(time)}
      _bad -> :error
    end
  end

  defp expires_at(_none), do: :error

  # The header for that one command, scoped to the clone URL's host so no other
  # remote is sent it; GitHub takes an installation token as basic auth.
  defp env(token, clone_url) do
    uri = URI.parse(clone_url)

    key =
      if uri.scheme in ["http", "https"] and is_binary(uri.host),
        do: "http.#{%URI{scheme: uri.scheme, host: uri.host, port: uri.port}}/.extraHeader",
        else: "http.extraHeader"

    basic = Base.encode64("x-access-token:" <> token)

    [
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", key},
      {"GIT_CONFIG_VALUE_0", "Authorization: Basic " <> basic}
    ]
  end
end
