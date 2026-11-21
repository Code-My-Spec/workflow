defmodule Workflow.JustfileTest do
  use ExUnit.Case
  @moduletag :tmp_dir

  # Excluded by default (test_helper.exs): `just certify` shells out to a real
  # `mix test`, which would otherwise run this very test again.
  @tag :real_just
  test "sarif: criterion 4", %{tmp_dir: dir} do
    assert {_, 0} =
             System.cmd("just", ["certify", dir], cd: File.cwd!(), stderr_to_stdout: true)

    assert File.exists?(Path.join(dir, "compiler.sarif"))
    assert File.exists?(Path.join(dir, "exunit.sarif"))

    meta = dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
    assert meta["analyzer_calls"]["compiler"] == "mix compile --warnings-as-errors"
    assert meta["analyzer_calls"]["exunit"] == "mix test"
  end
end
