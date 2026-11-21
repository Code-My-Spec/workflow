defmodule Mix.Tasks.Workflow.Sarif do
  @moduledoc """
  Runs a command and writes its outcome as a SARIF 2.1.0 file, for a recipe to
  use when the tool it calls does not write SARIF itself.

      mix workflow.sarif <output file> -- <command> [args...]

  The tool is named after the output file (its basename without `.sarif`). No
  results when the command exits 0. When a `mix test` run fails, one error
  result per failing test, with its name, failure text and file and line.
  Otherwise (another command, or a test run that died before any test failed)
  one error result with the last 4000 characters of its output. Exits with the
  command's status, and records the call in `meta.json` beside the output file.
  """
  @shortdoc "Runs a command and records its outcome as SARIF"

  use Mix.Task

  alias Workflow.Sarif

  @impl true
  def run([output, "--" | [command | args]]) do
    name = output |> Path.basename() |> String.replace_suffix(".sarif", "")

    started = System.monotonic_time(:millisecond)
    {out, status} = System.cmd(command, args, stderr_to_stdout: true)
    took_ms = System.monotonic_time(:millisecond) - started

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Jason.encode!(sarif(name, results(command, args, out, status))))

    Sarif.merge_meta(Path.dirname(output), %{
      "analyzer_calls" => %{name => Enum.join([command | args], " ")},
      "analyzers" => %{
        name => %{
          "at" => DateTime.to_iso8601(DateTime.utc_now()),
          "took_ms" => took_ms,
          "exit" => status
        }
      }
    })

    System.halt(status)
  end

  defp sarif(name, results) do
    %{
      "version" => "2.1.0",
      "runs" => [%{"tool" => %{"driver" => %{"name" => name}}, "results" => results}]
    }
  end

  defp results(_command, _args, _out, 0), do: []

  defp results("mix", ["test" | _], out, _status) do
    case test_failures(out) do
      [] -> tail(out)
      failures -> failures
    end
  end

  defp results(_command, _args, out, _status), do: tail(out)

  defp tail(out),
    do: [%{"level" => "error", "message" => %{"text" => String.slice(out, -4000, 4000)}}]

  # ExUnit prints each failure as `  N) test name (Module)`, then `file:line`,
  # then the failure text, before the closing `Finished in` summary.
  defp test_failures(out) do
    out
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.split(~r/\nFinished in /)
    |> hd()
    |> String.split(~r/^ +\d+\) /m)
    |> tl()
    |> Enum.flat_map(fn chunk ->
      case Regex.run(~r/\A([^\n]*)\n\s*([^\n]+):(\d+)\n(.*)\z/s, chunk) do
        [_, title, file, line, body] ->
          [
            %{
              "level" => "error",
              "message" => %{"text" => String.slice("#{title}\n#{String.trim(body)}", 0, 2000)},
              "locations" => [
                %{
                  "physicalLocation" => %{
                    "artifactLocation" => %{"uri" => file},
                    "region" => %{"startLine" => String.to_integer(line)}
                  }
                }
              ]
            }
          ]

        nil ->
          []
      end
    end)
  end
end
