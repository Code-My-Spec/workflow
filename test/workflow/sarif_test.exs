defmodule Workflow.SarifTest do
  use ExUnit.Case
  @moduletag :tmp_dir

  defp write_sarif(dir, name, results) do
    sarif = %{
      "version" => "2.1.0",
      "runs" => [%{"tool" => %{"driver" => %{"name" => name}}, "results" => results}]
    }

    File.write!(Path.join(dir, "#{name}.sarif"), Jason.encode!(sarif))
  end

  test "an error result fails with its message in the note", %{tmp_dir: dir} do
    write_sarif(dir, "compiler", [%{"level" => "error", "message" => %{"text" => "boom"}}])

    assert %{"status" => "failed", "note" => note, "dir" => ^dir} = Workflow.Sarif.verdict(dir)
    assert note =~ "compiler: boom"
  end

  test "an error result with a location names the file and line", %{tmp_dir: dir} do
    write_sarif(dir, "compiler", [
      %{
        "level" => "error",
        "message" => %{"text" => "boom"},
        "locations" => [
          %{
            "physicalLocation" => %{
              "artifactLocation" => %{"uri" => "lib/a.ex"},
              "region" => %{"startLine" => 12}
            }
          }
        ]
      }
    ])

    assert %{"note" => note} = Workflow.Sarif.verdict(dir)
    assert note =~ "lib/a.ex:12"
  end

  test "warnings alone pass", %{tmp_dir: dir} do
    write_sarif(dir, "compiler", [%{"level" => "warning", "message" => %{"text" => "meh"}}])

    assert Workflow.Sarif.verdict(dir) == %{"status" => "passed", "dir" => dir}
  end

  test "a non-zero exit with no error result fails with the output", %{tmp_dir: dir} do
    assert Workflow.Sarif.verdict(dir, 1, "boom") == %{
             "status" => "failed",
             "note" => "boom",
             "dir" => dir
           }
  end

  test "meta.json carries the tree, keeps what else is there, and keeps only the latest call for an analyzer run twice",
       %{tmp_dir: dir} do
    Workflow.Sarif.merge_meta(dir, %{"other" => "kept"})

    Workflow.Sarif.merge_meta(dir, %{
      "analyzer_calls" => %{"exunit" => "mix test"},
      "analyzers" => %{"exunit" => %{"at" => "a1", "took_ms" => 1, "exit" => 1}}
    })

    Workflow.Sarif.merge_meta(dir, %{
      "analyzer_calls" => %{"exunit" => "mix test --trace"},
      "analyzers" => %{"exunit" => %{"at" => "a2", "took_ms" => 2, "exit" => 0}}
    })

    Workflow.Sarif.merge_meta(dir, %{
      "recipes" => %{"run" => %{"at" => "a3", "took_ms" => 3, "exit" => 0}}
    })

    meta = Workflow.Sarif.meta(dir)

    assert meta["tree"] == Path.basename(dir)
    assert meta["other"] == "kept"
    assert meta["analyzer_calls"]["exunit"] == "mix test --trace"
    assert meta["analyzers"]["exunit"]["at"] == "a2"
    assert meta["recipes"]["run"]["exit"] == 0
  end
end
