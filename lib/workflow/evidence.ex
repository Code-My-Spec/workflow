defmodule Workflow.Evidence do
  @moduledoc """
  Sends a green ci run's evidence to the server. The contract is a folder: the
  ci recipe is given its run folder, and a project that wants evidence writes
  `<dir>/evidence/<journey id>/` holding that journey's stage screenshots
  (`.png`). Each sub-folder with at least one `.png` is sent, its `.png` files
  plus `stories/<journey id>.yml` from the ci checkout when there is one:
  `POST <server>/api/loop/evidence` with the loop's bearer token and
  `{project_id, commit, journey, files}`, answered `{folder, puts: {name: url}}`,
  then a PUT of each file to its url.

  No folder, or no `.png`, sends nothing and logs nothing. Any failure logs one
  warning and stops the upload; it never changes ci's result.

  Every request goes through an `http` function,
  `(:post | :put, url, opts) -> {:ok, status, body} | {:error, reason}`, where
  `opts` is `json:` and `auth:` for the POST, `body:` and `headers:` for a PUT.
  """
  require Logger

  @type http :: (:post | :put, String.t(), keyword() ->
                   {:ok, non_neg_integer(), term()} | {:error, term()})

  @doc """
  Uploads the evidence in run folder `run` for `commit`, reading story files from
  `project` (the project's folder in the ci checkout), to `server`. Nil `server`
  sends nothing. Always answers `:ok`.
  """
  @spec upload(String.t(), String.t(), String.t(), map() | nil, http()) :: :ok
  def upload(run, project, commit, server, http \\ default_http())

  def upload(_run, _project, _commit, nil, _http), do: :ok

  def upload(run, project, commit, %{"url" => url} = server, http) do
    journeys = journeys(Path.join(run, "evidence"), project)

    if journeys != [] do
      try do
        token =
          Workflow.SignIn.token(server) ||
            throw(
              {:failed, "no sign-in for #{Workflow.SignIn.base(url)}; run `workflow sign-in`"}
            )

        endpoint = Workflow.SignIn.base(url) <> "/api/loop/evidence"

        for {journey, files} <- journeys,
            do: send_journey(http, endpoint, token, server, commit, journey, files)
      catch
        {:failed, why} -> warn(why)
        kind, why -> warn(Exception.format_banner(kind, why))
      end
    end

    :ok
  end

  defp warn(why), do: Logger.warning("[Workflow.Evidence] evidence not uploaded: #{why}")

  # Each journey folder with a .png: its .png files, then its story file if the checkout has one.
  defp journeys(evidence, project) do
    case File.ls(evidence) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            folder = Path.join(evidence, name),
            File.dir?(folder),
            pngs = folder |> File.ls!() |> Enum.filter(&png?/1) |> Enum.sort(),
            pngs != [] do
          story = Path.join([project, "stories", name <> ".yml"])
          story = if File.regular?(story), do: [{name <> ".yml", story}], else: []
          {name, for(png <- pngs, do: {png, Path.join(folder, png)}) ++ story}
        end

      _none ->
        []
    end
  end

  defp png?(name), do: String.downcase(Path.extname(name)) == ".png"

  defp send_journey(http, endpoint, token, server, commit, journey, files) do
    body = %{
      "project_id" => server["project_id"],
      "commit" => commit,
      "journey" => journey,
      "files" => Enum.map(files, &elem(&1, 0))
    }

    puts =
      case http.(:post, endpoint, json: body, auth: {:bearer, token}) do
        {:ok, status, %{"puts" => %{} = puts}} when status in 200..299 -> puts
        {:ok, status, _body} -> throw({:failed, "the POST for #{journey} answered #{status}"})
        {:error, why} -> throw({:failed, "the POST for #{journey} failed: #{inspect(why)}"})
      end

    for {name, path} <- files do
      url = puts[name] || throw({:failed, "the server gave no url for #{journey}/#{name}"})
      type = if png?(name), do: "image/png", else: "application/yaml"

      case http.(:put, url, body: File.read!(path), headers: [{"content-type", type}]) do
        {:ok, status, _body} when status in 200..299 ->
          :ok

        {:ok, status, _body} ->
          throw({:failed, "the PUT of #{journey}/#{name} answered #{status}"})

        {:error, why} ->
          throw({:failed, "the PUT of #{journey}/#{name} failed: #{inspect(why)}"})
      end
    end
  end

  defp default_http, do: Application.get_env(:workflow, :evidence_http, &request/3)

  @doc "The real `http` function, by Req."
  def request(method, url, opts) do
    case Req.request([method: method, url: url, retry: false] ++ opts) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end
end
