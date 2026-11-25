defmodule Workflow.CiPoll do
  @moduledoc """
  Asks the work's server for its ci verdict while the work waits at its `ci`
  step: `GET <server>/api/ci/<full sha of the commit it landed as>`, with the
  loop's own sign-in token (`Workflow.SignIn.token/2`), as `Workflow.CloneToken`
  sends it. An answer is recorded as the ci event (`Workflow.Run.event/3`); a
  404, or no answer at all, means no verdict yet, and the server is asked again
  every `:ci_interval` milliseconds (60 seconds). Asking stops once the work
  leaves ci or is stopped. The token is never logged or kept.
  """

  alias Workflow.Checkout

  @interval 60_000

  @doc """
  Starts asking for the work's verdict, in a process of its own, one a checkout.
  With no server configured, or no landed commit, nothing is asked.
  """
  @spec start(map()) :: :ok
  def start(%{"id" => id, "root" => root}) do
    with %{"url" => "" <> _} = server <- Application.get_env(:workflow, :server),
         "" <> sha <- landed(root, id) do
      # Spawned, not a task: it outlives whoever left the work at ci.
      spawn(fn ->
        if :global.register_name({__MODULE__, root}, self()) == :yes,
          do: poll(server, id, root, sha)
      end)
    end

    :ok
  end

  def start(_no_copy), do: :ok

  defp poll(server, id, root, sha) do
    if waiting?(id, root, sha) do
      case ask(server, sha) do
        {:ok, verdict} ->
          Workflow.Run.event(id, "ci", verdict)

        :none ->
          Process.sleep(Application.get_env(:workflow, :ci_interval, @interval))
          poll(server, id, root, sha)
      end
    end
  end

  # The commit promote landed the tree the work is at as, while no ci is recorded there.
  defp landed(root, id) do
    with %{} = snapshot <- Checkout.snapshot(root, id),
         nil <- Workflow.Parts.found(snapshot, "ci"),
         %{"status" => "promoted", "commit" => "" <> sha} <-
           Workflow.Parts.found(snapshot, "promote") do
      sha
    else
      _none -> nil
    end
  end

  # Still in flight, not stopped, and at the same landed commit with no verdict.
  defp waiting?(id, root, sha) do
    File.exists?(Path.join(Workflow.Run.works_dir(), "#{id}.json")) and
      is_nil(Checkout.stopped(root, id)) and landed(root, id) == sha
  end

  defp ask(server, sha) do
    with "" <> bearer <- Workflow.SignIn.token(server),
         {:ok, %Req.Response{status: 200, body: %{} = body}} <-
           Req.get(Workflow.SignIn.base(server["url"]) <> "/api/ci/" <> sha,
             headers: [{"authorization", "Bearer " <> bearer}],
             retry: false
           ) do
      {:ok, verdict(body)}
    else
      _no_verdict -> :none
    end
  end

  # The ci event's body: its payload, or the payload itself.
  defp verdict(%{"name" => "ci", "payload" => %{} = payload}), do: payload
  defp verdict(body), do: body
end
