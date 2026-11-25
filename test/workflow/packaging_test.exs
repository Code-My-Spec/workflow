defmodule Workflow.PackagingTest do
  use ExUnit.Case, async: true

  @tarball "codemyspec-darwin-arm64.tar.gz"

  defp read(path), do: File.read!(Path.join(File.cwd!(), path))

  # The lines of a justfile recipe: its header (with or without arguments) and the indented lines under it.
  defp recipe(justfile, name) do
    justfile
    |> String.split("\n")
    |> Enum.drop_while(
      &(not (String.starts_with?(&1, name <> ":") or String.starts_with?(&1, name <> " ")))
    )
    |> case do
      [] -> []
      [_header | rest] -> Enum.take_while(rest, &String.starts_with?(&1, "    "))
    end
    |> Enum.join("\n")
  end

  test "packaging-is-real: the justfile, the formula and the READMEs give an exact recipe" do
    # 1. `just package` builds the prod release and the tarball and prints its sha256.
    package = recipe(read("justfile"), "package")
    assert package =~ "MIX_ENV=prod mix release"
    assert package =~ "tar "
    assert package =~ @tarball
    assert package =~ "shasum -a 256"

    # 2. The formula is a template: its url and sha256 are its only placeholders.
    formula = read("packaging/codemyspec.rb")
    assert formula =~ ~s(url "__URL__")
    assert formula =~ ~s(sha256 "__SHA256__")

    assert Regex.scan(~r/__[A-Z0-9]+__/, formula) |> List.flatten() |> Enum.uniq() |> Enum.sort() ==
             ["__SHA256__", "__URL__"]

    assert formula =~ ~s(depends_on "git")
    assert formula =~ ~s(depends_on "just")
    assert formula =~ ~s(bin/"workflow")

    # 3. Its caveats name `workflow sign-in` and Claude Code.
    [_, caveats] = Regex.run(~r/def caveats\n(.*?)\n  end\n/s, formula)
    assert caveats =~ "workflow sign-in"
    assert caveats =~ "Claude Code"
    assert caveats =~ "`claude`"

    # 4. README.md opens with an install section, in order.
    [first_section | _] =
      read("README.md") |> String.split(~r/^## /m) |> Enum.drop(1)

    assert first_section =~ ~r/^Install\n/
    brew = :binary.match(first_section, "brew install")
    sign_in = :binary.match(first_section, "workflow sign-in")
    claude = :binary.match(first_section, "Claude Code")
    assert brew != :nomatch and sign_in != :nomatch and claude != :nomatch
    assert brew < sign_in and sign_in < claude

    # packaging/README.md gives the same steps, with the same names.
    steps = read("packaging/README.md")
    assert steps =~ "just package"
    assert steps =~ "packaging/codemyspec.rb"
    assert steps =~ @tarball
    assert steps =~ "`url`"
    assert steps =~ "`sha256`"
    assert steps =~ "workflow sign-in"

    # It gives the by-hand steps, publishing nothing: run `just package`, fill the
    # formula's own placeholders in from what it printed, and hand off.
    [_, by_hand] = Regex.run(~r/^## Build by hand[^\n]*\n(.*?)(?=^## |\z)/ms, steps)
    assert by_hand =~ ~r/^    just package <app>$/m
    assert by_hand =~ "__URL__"
    assert by_hand =~ "__SHA256__"
    refute by_hand =~ "__VERSION__"
    assert by_hand =~ "hand off"
  end
end
