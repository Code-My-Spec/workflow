defmodule Workflow.ApplicationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @tag :tmp_dir
  test "the start-up check logs one line per missing program and lets the boot carry on",
       %{tmp_dir: dir} do
    git = Path.join(dir, "git")
    File.write!(git, "#!/bin/sh\n")
    File.chmod!(git, 0o755)

    log =
      capture_log(fn ->
        assert Workflow.Application.check_path(dir) == :ok
      end)

    lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "not on PATH"))

    assert [claude] = Enum.filter(lines, &(&1 =~ "`claude`"))
    assert claude =~ "no agent turn can run"
    assert [just] = Enum.filter(lines, &(&1 =~ "`just`"))
    assert just =~ "a project's checks and commands can't run"
    assert Enum.filter(lines, &(&1 =~ "`git`")) == []
    assert length(lines) == 2
  end
end
