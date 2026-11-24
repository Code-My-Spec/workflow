defmodule Workflow.Devops do
  @moduledoc """
  A DevOps work: the project's `devops.yml` run through the DevOps plugin's
  scripts for one `"environment"`, by its `"action"`, "check" (every probe) or
  "apply" (each step's apply, then its probe).

  The system resolves `devops.yml` with the plugin's `bin/resolve.exs`
  (`resolve`), and stops, naming each line that resolves to no script. It then
  runs each resolved step of the environment, in file order, its apply (an apply
  work's first round only) and then its probe (`probe`). Each script's stdout is
  one event a line, each sent to the server as one of the work's reports
  (`Workflow.Report.events/3`); its exit code is pass (0) or fail. The probe is
  the truth: a step passes only when its probe does. A failed probe goes to the
  coder, with the devops skill and the provider's words (`fix`), and the probes
  run again after its turn; after `@retries` such turns the work waits on a
  person (`person`), its stop note the last probe's words.

  The DevOps plugin is the loop's plugin folder (`Workflow.Plugin.dir/0`) when
  it has `bin/resolve.exs`, else the folder `devops` beside it.
  """

  @behaviour Workflow.Template

  alias Workflow.Checkout

  # How many times a failed probe goes to the coder before the work waits on a person.
  @retries 3

  @doc "How many times a failed probe goes to the coder before the work waits on a person."
  @spec retries() :: pos_integer()
  def retries, do: @retries

  @brief "You are the coder on one DevOps work in this checkout. A probe of the project's " <>
           "devops.yml failed: your note gives the provider's words. Find and fix the cause " <>
           "with the devops skill and the plugin's tools, then end your turn: the loop runs " <>
           "the probes again. This work has no review or promote, so a commit here does not land."

  @impl true
  def steps do
    [
      %{name: "resolve", actor: :system},
      %{name: "probe", actor: :system},
      %{
        name: "fix",
        actor: :coder,
        agent: %{tools: [:read, :edit, :write, :bash], brief: @brief, skills: skills()}
      },
      %{name: "person", actor: :owner}
    ]
  end

  @impl true
  def status(%{name: "resolve"}, snapshot) do
    case found(snapshot, "resolve") do
      %{"status" => "passed"} -> :done
      %{"status" => "refused", "note" => note} -> %{note: note, stop: true}
      nil -> %{}
    end
  end

  # Run again once the coder has had a turn since the probes last failed.
  def status(%{name: "probe"}, snapshot) do
    by = found(snapshot, "by")

    case found(snapshot, "probe") do
      nil -> %{}
      %{"status" => "passed"} -> :done
      %{"at" => at} -> if by && by["step"] == "fix" && by["at"] > at, do: %{}, else: :done
    end
  end

  def status(%{name: "fix"}, snapshot) do
    case found(snapshot, "probe") do
      %{"status" => "failed", "tries" => tries, "note" => note} when tries <= @retries ->
        %{
          note:
            "The probes failed (retry #{tries} of #{@retries}). The provider's words:\n\n" <>
              note <> "\n\nFix the cause, then end your turn: the probes run again."
        }

      _passed_or_spent ->
        :done
    end
  end

  def status(%{name: "person"}, snapshot) do
    case found(snapshot, "probe") do
      %{"status" => "failed", "note" => note} -> %{note: spent(note)}
      _passed -> :done
    end
  end

  @impl true
  def perform("resolve", %{"root" => root, "id" => id} = work, _snapshot) do
    case resolve(dir(root, work), work["environment"], &Workflow.Report.events(root, id, &1)) do
      {:ok, steps} -> %{"status" => "passed", "steps" => steps}
      {:refused, why} -> %{"status" => "refused", "note" => why}
    end
  end

  def perform("probe", %{"root" => root, "id" => id} = work, snapshot) do
    tries = tries(snapshot) + 1
    apply? = work["action"] == "apply" and tries == 1
    report = &Workflow.Report.events(root, id, &1)
    here = dir(root, work)

    checked =
      for step <- found(snapshot, "resolve")["steps"] do
        # Whatever its apply says, the probe decides the step.
        if apply?, do: script(step, "apply", here, report)
        {events, code} = script(step, "probe", here, report)
        status = if code == 0, do: "passed", else: "failed"
        %{"id" => step["id"], "status" => status, "words" => words(events)}
      end

    case for %{"status" => "failed"} = step <- checked, do: "#{step["id"]}: #{step["words"]}" do
      [] ->
        %{"status" => "passed", "tries" => tries, "at" => Checkout.now(), "steps" => checked}

      failed ->
        note = Enum.join(failed, "\n")

        # The retries are spent: the work waits on a person, saying the last probe's words.
        if tries > @retries,
          do: Checkout.stop(root, id, "person", "waiting on its owner: " <> spent(note))

        %{
          "status" => "failed",
          "tries" => tries,
          "at" => Checkout.now(),
          "steps" => checked,
          "note" => note
        }
    end
  end

  @doc """
  The steps of `devops.yml` in `dir` for `environment`, resolved by the plugin's
  `bin/resolve.exs`: `{:ok, steps}`, or `{:refused, why}` naming each line that
  resolves to no script (or saying there is no plugin, no file, or no line for
  the environment). The events resolve prints are handed to `report`.
  """
  @spec resolve(String.t(), String.t() | nil, ([map()] -> term())) ::
          {:ok, [map()]} | {:refused, String.t()}
  def resolve(dir, environment, report \\ fn _events -> :ok end) do
    yml = Path.join(dir, "devops.yml")

    cond do
      is_nil(plugin()) ->
        {:refused,
         "there is no DevOps plugin: neither the plugin folder nor a devops folder beside " <>
           "it has bin/resolve.exs"}

      not File.regular?(yml) ->
        {:refused, "there is no devops.yml in #{dir}"}

      true ->
        resolve = Path.join([plugin(), "bin", "resolve.exs"])
        {events, code} = run("elixir", [resolve, yml], dir, %{"phase" => "resolve"}, report)
        refused = for %{"event" => "refused"} = event <- events, do: event["message"]
        steps = for %{"event" => "step", "environment" => ^environment} = e <- events, do: e

        cond do
          refused != [] ->
            {:refused, "devops.yml has lines with no script: " <> Enum.join(refused, "; ")}

          code != 0 ->
            {:refused, "bin/resolve.exs failed (exit #{code}): #{words(events)}"}

          steps == [] ->
            {:refused, "devops.yml has no line for the environment #{inspect(environment)}"}

          true ->
            {:ok, steps}
        end
    end
  end

  @doc "The DevOps plugin's folder, or nil with none (see the moduledoc)."
  @spec plugin() :: String.t() | nil
  def plugin do
    with "" <> dir <- Workflow.Plugin.dir() do
      dir = Path.expand(dir)

      Enum.find(
        [dir, Path.join(Path.dirname(dir), "devops")],
        &File.regular?(Path.join([&1, "bin", "resolve.exs"]))
      )
    end
  end

  # The coder's devops skill, from the plugin.
  defp skills do
    with "" <> plugin <- plugin(),
         skill = Path.join([plugin, "skills", "devops"]),
         true <- File.dir?(skill) do
      [skill]
    else
      _none -> nil
    end
  end

  # One of a resolved step's scripts, with its environment and settings.
  defp script(step, phase, dir, report) do
    path = Path.expand(step[phase], plugin())
    args = [step["environment"] | List.wrap(step["settings"])]
    run(path, args, dir, %{"step" => step["id"], "phase" => phase}, report)
  end

  # One event a stdout line, tagged, all reported as the script ends; a line
  # that is no JSON object is kept as its text.
  defp run(command, args, dir, tag, report) do
    {out, code} =
      Checkout.cmd(command, args, cd: dir, env: Workflow.Plugin.env(), stderr_to_stdout: true)

    events =
      for line <- String.split(out, ~r/\r?\n/, trim: true) do
        event =
          case Jason.decode(line) do
            {:ok, %{} = event} -> event
            _not_an_event -> %{"event" => "output", "text" => line}
          end

        Map.merge(event, tag)
      end

    report.(events)
    {events, code}
  end

  # The provider's words: the last event's message or reason, else its text.
  defp words(events) do
    Enum.find_value(Enum.reverse(events), "it said nothing", fn event ->
      Enum.find_value(["message", "reason", "text"], &(is_binary(event[&1]) && event[&1]))
    end)
  end

  defp spent(note), do: "the probes still fail after #{@retries} retries:\n\n#{note}"

  # The probe rounds run so far, at any tree of the work.
  defp tries(%{results: results}) do
    results
    |> Map.values()
    |> Enum.map(&(is_map(&1) && is_map(&1["probe"]) && &1["probe"]["tries"]))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  defp dir(root, work), do: Path.join(root, work["project"] || ".")

  defp found(%{head: head, results: results}, step), do: get_in(results, [head, step])
end
