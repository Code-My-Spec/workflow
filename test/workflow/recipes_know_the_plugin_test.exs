defmodule Workflow.RecipesKnowThePluginTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Workflow.Checkout

  setup do
    Workflow.Tellings.quiet()
    stand_in = Application.get_env(:workflow, :cmd)
    plugin = Application.get_env(:workflow, :plugin)
    inherited = System.get_env("CODEMYSPEC_PLUGIN")
    Application.delete_env(:workflow, :cmd)
    System.delete_env("CODEMYSPEC_PLUGIN")

    on_exit(fn ->
      if stand_in, do: Application.put_env(:workflow, :cmd, stand_in)

      if plugin,
        do: Application.put_env(:workflow, :plugin, plugin),
        else: Application.delete_env(:workflow, :plugin)

      if inherited, do: System.put_env("CODEMYSPEC_PLUGIN", inherited)
      Workflow.Tellings.quiet()
    end)
  end

  # A git repo whose every recipe writes what it was given as CODEMYSPEC_PLUGIN
  # ("unset" when it was not set) into `out`; certify writes EXTRA too.
  defp project(base, name) do
    repo = Path.join(base, name)
    out = Path.join(base, "#{name}-out")
    File.mkdir_p!(repo)
    File.mkdir_p!(out)

    echo = fn file, extra ->
      ~s(    printf '%s' "${CODEMYSPEC_PLUGIN-unset}#{extra}" > "#{Path.join(out, file)}"\n)
    end

    File.write!(
      Path.join(repo, "justfile"),
      "copy-setup:\n" <>
        echo.("copy-setup", "") <>
        "copy-teardown:\n" <>
        echo.("copy-teardown", "") <>
        "run dir:\n" <>
        echo.("run", "") <>
        "certify dir:\n" <>
        echo.("certify", " ${EXTRA-unset}") <>
        "demo dir:\n" <> echo.("demo", "")
    )

    git = fn args -> {_, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true) end
    git.(~w(init -q -b main))
    git.(~w(add justfile))
    git.(~w(-c user.name=t -c user.email=t@example.com commit -q -m start))

    root = Checkout.own(repo, "issue", "plugin-#{name}", nil)
    assert is_binary(root)
    Checkout.test(root, nil)
    Checkout.analyse(root, nil, "certify", [{"EXTRA", "given"}])
    Checkout.demo(root, nil)
    Checkout.disown(repo, "issue", "plugin-#{name}", nil)

    Map.new(~w(copy-setup copy-teardown run certify demo), fn file ->
      {file, File.read!(Path.join(out, file))}
    end)
  end

  test "recipes get CODEMYSPEC_PLUGIN as the configured plugin's absolute path, none without one, merged with a call's own env",
       %{tmp_dir: tmp_dir} do
    plugin = Path.join(tmp_dir, "plugin")
    File.mkdir_p!(plugin)
    assert Path.type(plugin) == :absolute

    Application.put_env(:workflow, :plugin, plugin)
    seen = project(tmp_dir, "with")

    assert seen == %{
             "copy-setup" => plugin,
             "copy-teardown" => plugin,
             "run" => plugin,
             "certify" => plugin <> " given",
             "demo" => plugin
           }

    Application.delete_env(:workflow, :plugin)
    seen = project(tmp_dir, "without")

    assert seen == %{
             "copy-setup" => "unset",
             "copy-teardown" => "unset",
             "run" => "unset",
             "certify" => "unset given",
             "demo" => "unset"
           }
  end
end
