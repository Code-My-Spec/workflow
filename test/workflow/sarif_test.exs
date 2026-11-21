defmodule Workflow.SarifTest do
  use ExUnit.Case
  @moduletag :tmp_dir

  test "sarif: criterion 1", %{tmp_dir: dir} do
    passing = Path.join(dir, "passer.sarif")
    failing = Path.join(dir, "failer.sarif")

    assert {_, 0} =
             System.cmd("mix", ["workflow.sarif", passing, "--", "true"], stderr_to_stdout: true)

    assert %{"version" => "2.1.0", "runs" => [passer_run]} =
             passing |> File.read!() |> Jason.decode!()

    assert %{"tool" => %{"driver" => %{"name" => "passer"}}, "results" => []} = passer_run

    assert {_, 7} =
             System.cmd(
               "mix",
               ["workflow.sarif", failing, "--", "sh", "-c", "printf hello-failure; exit 7"],
               stderr_to_stdout: true
             )

    assert %{"runs" => [%{"results" => [result]}]} = failing |> File.read!() |> Jason.decode!()
    assert result["level"] == "error"
    assert result["message"]["text"] =~ "hello-failure"

    meta = dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
    # Both analyzers are kept: the second call does not erase the first's entry.
    assert meta["analyzer_calls"]["passer"] == "true"
    assert meta["analyzer_calls"]["failer"] == "sh -c printf hello-failure; exit 7"
    assert meta["analyzers"]["passer"]["exit"] == 0
    assert meta["analyzers"]["failer"]["exit"] == 7
  end

  test "test-failures-by-name: criterion 1", %{tmp_dir: dir} do
    inner = Path.join(dir, "inner_fails_test.exs")

    File.write!(inner, """
    defmodule InnerFailsTest do
      use ExUnit.Case

      test "alpha breaks" do
        assert 1 == 2
      end

      test "beta breaks" do
        assert 3 == 4
      end

      test "gamma holds" do
        assert true
      end
    end
    """)

    out = Path.join(dir, "exunit.sarif")

    assert {_, status} =
             System.cmd("mix", ["workflow.sarif", out, "--", "mix", "test", inner],
               stderr_to_stdout: true
             )

    assert status != 0

    assert %{"runs" => [%{"results" => results}]} = out |> File.read!() |> Jason.decode!()
    assert length(results) == 2

    for {name, line} <- [{"alpha breaks", 4}, {"beta breaks", 8}] do
      result = Enum.find(results, &(&1["message"]["text"] =~ name))
      assert result, "no result for #{name}"
      assert result["level"] == "error"
      text = result["message"]["text"]
      assert text =~ ~r/\A\W*(test )?#{name}/
      assert text =~ "Assertion"
      assert String.length(text) <= 2000

      assert [%{"physicalLocation" => loc}] = result["locations"]
      assert loc["artifactLocation"]["uri"] =~ "inner_fails_test.exs"
      assert loc["region"]["startLine"] == line
    end
  end

  test "test-failures-by-name: criterion 2", %{tmp_dir: dir} do
    inner = Path.join(dir, "inner_passes_test.exs")

    File.write!(inner, """
    defmodule InnerPassesTest do
      use ExUnit.Case

      test "one holds" do
        assert 1 == 1
      end

      test "two holds" do
        assert true
      end
    end
    """)

    out = Path.join(dir, "exunit.sarif")

    assert {_, 0} =
             System.cmd("mix", ["workflow.sarif", out, "--", "mix", "test", inner],
               stderr_to_stdout: true
             )

    assert %{"runs" => [%{"results" => []}]} = out |> File.read!() |> Jason.decode!()
  end

  test "test-failures-by-name: criterion 3", %{tmp_dir: dir} do
    out = Path.join(dir, "other.sarif")

    script =
      "echo first-line; i=0; while [ $i -lt 1000 ]; do echo filler-line-$i; i=$((i+1)); done; echo last-line; exit 5"

    assert {_, 5} =
             System.cmd("mix", ["workflow.sarif", out, "--", "sh", "-c", script],
               stderr_to_stdout: true
             )

    assert %{"runs" => [%{"results" => [result]}]} = out |> File.read!() |> Jason.decode!()
    assert result["level"] == "error"
    text = result["message"]["text"]
    assert text =~ "last-line"
    refute text =~ "first-line"
    assert String.length(text) <= 4000
  end

  test "test-failures-by-name: criterion 4", %{tmp_dir: dir} do
    inner = Path.join(dir, "inner_broken_test.exs")

    File.write!(inner, """
    defmodule InnerBrokenTest do
      use ExUnit.Case

      test "never runs" do
        assert true
      end

      this is not valid elixir (
    end
    """)

    out = Path.join(dir, "exunit.sarif")

    assert {_, status} =
             System.cmd("mix", ["workflow.sarif", out, "--", "mix", "test", inner],
               stderr_to_stdout: true
             )

    assert status != 0

    assert %{"runs" => [%{"results" => [result]}]} = out |> File.read!() |> Jason.decode!()
    assert result["level"] == "error"
    assert result["message"]["text"] =~ "inner_broken_test.exs"
    refute Map.has_key?(result, "locations")
  end

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
