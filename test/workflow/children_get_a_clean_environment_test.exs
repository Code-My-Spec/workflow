defmodule Workflow.ChildrenGetACleanEnvironmentTest do
  use ExUnit.Case, async: false

  @release ~w(RELEASE_ROOT RELEASE_NODE ROOTDIR BINDIR EMU PROGNAME MIX_HOME ERL_LIBS)

  test "a command run in a project gets none of the release's variables, and the rest" do
    before = Map.new(@release ++ ["ORDINARY_VAR"], &{&1, System.get_env(&1)})
    stand_in = Application.get_env(:workflow, :cmd)
    Application.delete_env(:workflow, :cmd)

    on_exit(fn ->
      Enum.each(before, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      if stand_in, do: Application.put_env(:workflow, :cmd, stand_in)
    end)

    Enum.each(@release, &System.put_env(&1, "from-the-release"))
    System.put_env("ORDINARY_VAR", "kept")

    {out, 0} = Workflow.Checkout.cmd("env", [], cd: System.tmp_dir!(), stderr_to_stdout: true)

    names = out |> String.split("\n") |> Enum.map(&(&1 |> String.split("=") |> hd()))

    for name <- @release, do: refute(name in names, "#{name} reached the child")
    assert "ORDINARY_VAR=kept" in String.split(out, "\n")
    assert "PATH=#{System.get_env("PATH")}" in String.split(out, "\n")
  end
end
