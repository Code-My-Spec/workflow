defmodule Workflow.Upload do
  @moduledoc """
  The evidence a `just certify` or `just run` of the loop's leaves in the
  copy, sent to the server over the loop's channel (`Workflow.Server`).

  The recipe is given EVIDENCE_CONTEXT (`certify/<work id>`, `run/<work id>` or `demo/<work id>`)
  and one EVIDENCE_CORRELATION uuid. Afterwards each new
  `.code_my_spec/evidence/*.sarif` file and each file in a new `<guid>/` folder
  there is sent: `presign` `{project_id, files}` is pushed and answers
  `{puts: {name: url}}`, each file is PUT to its url with no auth header, and
  `uploaded` `{project_id, guids}` is pushed. What was sent is then deleted.

  With no server, no reply, or a failed PUT, one line is logged and the files
  are left; nothing else changes.
  """
  require Logger

  @doc "The variables a recipe run for `context` is given; none without one."
  @spec env(String.t() | nil) :: [{String.t(), String.t()}]
  def env(nil), do: []

  def env(context),
    do: [{"EVIDENCE_CONTEXT", context}, {"EVIDENCE_CORRELATION", uuid()}]

  @doc "The evidence files in `project`, by their names under its evidence folder."
  @spec evidence(String.t()) :: [String.t()]
  def evidence(project) do
    dir = folder(project)

    for path <- Path.wildcard(Path.join(dir, "*.sarif")) ++ Path.wildcard(Path.join(dir, "*/**")),
        File.regular?(path),
        do: Path.relative_to(path, dir)
  end

  @doc "Sends the evidence in `project` that is not in `before`, then deletes it. Always `:ok`."
  @spec upload(String.t(), [String.t()]) :: :ok
  def upload(project, before) do
    dir = folder(project)

    case evidence(project) -- before do
      [] -> :ok
      files -> send_files(dir, files)
    end
  end

  defp send_files(dir, files) do
    project_id = (Application.get_env(:workflow, :server) || %{})["project_id"]

    guids =
      files
      |> Enum.map(&Path.split/1)
      |> Enum.filter(&match?([_, _ | _], &1))
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    with {:ok, %{"puts" => %{} = puts}} <-
           Workflow.Server.call("presign", %{"project_id" => project_id, "files" => files}),
         :ok <- put_all(dir, files, puts) do
      Workflow.Server.push("uploaded", %{"project_id" => project_id, "guids" => guids})
      for file <- files, do: File.rm(Path.join(dir, file))
      for guid <- guids, do: File.rm_rf(Path.join(dir, guid))
      :ok
    else
      why -> Logger.warning("[Workflow.Upload] evidence not uploaded: #{inspect(why)}")
    end

    :ok
  end

  defp put_all(dir, files, puts) do
    Enum.find_value(files, :ok, fn file ->
      case puts[file] && http().(:put, puts[file], body: File.read!(Path.join(dir, file))) do
        nil -> {:no_url, file}
        {:ok, status, _body} when status in 200..299 -> nil
        other -> {:put, file, other}
      end
    end)
  end

  defp folder(project), do: Path.join([project, ".code_my_spec", "evidence"])

  # `(:put, url, opts) -> {:ok, status, body} | {:error, why}`, or what a test puts in its place.
  defp http, do: Application.get_env(:workflow, :http, &request/3)

  @doc "The real `http` function, by Req."
  def request(method, url, opts) do
    case Req.request([method: method, url: url, retry: false] ++ opts) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = <<a::48, 4::4, b::12, 2::2, c::62>> |> Base.encode16(case: :lower)

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end
end
