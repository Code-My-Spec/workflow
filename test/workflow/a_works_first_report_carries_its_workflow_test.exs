defmodule Workflow.AWorksFirstReportCarriesItsWorkflowTest do
  # Not async: the server's settings and where works are kept are app-wide.
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Checkout

  setup %{tmp_dir: dir} do
    was = for key <- [:server, :manager, :works_dir], do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value == nil,
          do: Application.delete_env(:workflow, key),
          else: Application.put_env(:workflow, key, value)
      end
    end)

    Application.put_env(:workflow, :server, %{"url" => "ws://x", "project_id" => "p1"})
    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.delete_env(:workflow, :manager)

    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    File.write!(Path.join(main, "README"), "hi")

    for args <- [
          ~w(init -q -b main),
          ~w(config user.name t),
          ~w(config user.email t@example.com),
          ~w(add -A),
          ~w(commit -q -m first)
        ] do
      {_, 0} = System.cmd("git", args, cd: main, stderr_to_stdout: true)
    end

    %{main: main}
  end

  test "workflows-are-data: criterion 6 a work's first report carries the whole workflow it runs, before its second step",
       %{main: main} do
    work = %{"kind" => "issue", "id" => "i1", "root" => main, "title" => "Fix the thing"}
    Checkout.keep(main, "i1", work)

    # Nothing has run: the work is at its first step.
    assert %{"workflow" => workflow} = Workflow.Report.of(main, "i1")

    assert workflow["name"] == "issue"

    assert workflow["steps"] ==
             for(
               step <- Workflow.Workflows.steps!("issue"),
               do: %{"name" => step.name, "actor" => to_string(step.actor)}
             )

    # Issue has no verify, so none is carried.
    refute Map.has_key?(workflow, "verify")
  end
end
