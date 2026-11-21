defmodule Workflow.StaticReviewTest do
  use ExUnit.Case

  alias Workflow.StaticReview

  defp fake(output) do
    Application.put_env(:workflow, :cmd, fn
      "git", ["diff", "--stat", "main...HEAD"], _opts -> {output, 0}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)
  end

  test "static-review: criterion 1" do
    work = %{"root" => "/root"}
    snapshot = %{main: "main"}

    fake(" 1 file changed, 2 insertions(+)\n")
    assert StaticReview.section(work, snapshot) =~ "1 file changed, 2 insertions(+)"

    fake("")
    assert StaticReview.section(work, snapshot) == ""
  end

  defp use_plugin(dir) do
    Application.put_env(:workflow, :plugin, dir)
    on_exit(fn -> Application.delete_env(:workflow, :plugin) end)
  end

  @stat " mix.exs | 2 ++\n lib/foo.ex | 1 +\n test/login_spex.ex | 3 +++\n 3 files changed, 6 insertions(+)\n"

  @tag :tmp_dir
  test "plugin-is-the-skills: criterion 4 - the guards and the test-file match come from the plugin's guards file; with none there are no guards",
       %{tmp_dir: dir} do
    work = %{"root" => "/root"}
    snapshot = %{main: "main"}
    fake(" package.json | 2 ++\n mix.exs | 1 +\n src/a.test.js | 3 +++\n 3 files changed\n")

    use_plugin(dir)
    refute StaticReview.section(work, snapshot) =~ "test boundary"

    File.write!(Path.join(dir, "guards"), "# comment\npackage.json\n\n*.test.js\n")
    section = StaticReview.section(work, snapshot)

    assert section =~ "- package.json"
    assert section =~ "- src/a.test.js"
    refute section =~ "- mix.exs"
  end

  @tag :tmp_dir
  test "static-review: criterion 2", %{tmp_dir: dir} do
    work = %{"root" => "/root"}
    snapshot = %{main: "main"}
    # The guards an Elixir plugin carries.
    File.write!(Path.join(dir, "guards"), "mix.exs\n*_spex.ex\n")
    use_plugin(dir)

    fake(@stat)
    section = StaticReview.section(work, snapshot)

    assert section =~ "- mix.exs"
    assert section =~ "- test/login_spex.ex"
    assert section =~ "look at each"
    refute section =~ "- lib/foo.ex"

    with_guards = Map.put(work, "guards", ["lib/foo.ex"])
    custom = StaticReview.section(with_guards, snapshot)

    assert custom =~ "- lib/foo.ex"
    refute custom =~ "- mix.exs"
  end

  test "static-review: criterion 3" do
    work = %{"root" => "/root", "project" => "myproj"}

    snapshot = %{
      main: "main",
      head: "headtree",
      results: %{
        "t1" => %{"by" => %{"step" => "specify", "at" => "2024-01-01T00:00:00Z"}},
        "t2" => %{"by" => %{"step" => "specify", "at" => "2024-01-02T00:00:00Z"}},
        "t3" => %{"by" => %{"step" => "work", "at" => "2024-01-03T00:00:00Z"}},
        # What was said to the work is kept beside the trees, as a list.
        "said" => ["a message"]
      }
    }

    Application.put_env(:workflow, :cmd, fn
      "git", ["diff", "--stat", "main...HEAD"], _opts ->
        {"", 0}

      "git", ["diff", "t2", "headtree", "--stat", "--", "myproj/test"], _opts ->
        {" test/foo_test.exs | 4 ++--\n 1 file changed, 2 insertions(+), 2 deletions(-)\n", 0}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    assert StaticReview.section(work, snapshot) =~ "foo_test.exs"
  end

  test "static-review: criterion 4" do
    work = %{"root" => "/root"}

    snapshot = %{
      main: "main",
      results: %{
        "t1" => %{"specify" => %{"status" => "pass", "note" => "Already validates emails."}},
        "t2" => %{"specify" => %{"status" => "fail", "note" => "not done"}}
      }
    }

    fake("")

    section = StaticReview.section(work, snapshot)
    assert section =~ "Already validates emails."
    refute section =~ "not done"
  end

  test "static-review: a list-valued kept result beside a specify result is skipped" do
    work = %{"root" => "/root", "project" => "myproj"}

    snapshot = %{
      main: "main",
      head: "headtree",
      results: %{
        "tell" => ["please also cover the login page"],
        "t1" => %{"by" => %{"step" => "specify", "at" => "2024-01-01T00:00:00Z"}}
      }
    }

    Application.put_env(:workflow, :cmd, fn
      "git", ["diff", "--stat", "main...HEAD"], _opts ->
        {"", 0}

      "git", ["diff", "t1", "headtree", "--stat", "--", "myproj/test"], _opts ->
        {" test/foo_test.exs | 4 ++--\n 1 file changed, 2 insertions(+), 2 deletions(-)\n", 0}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)

    assert StaticReview.section(work, snapshot) =~ "foo_test.exs"
  end

  test "static-review: empty when there is nothing to report" do
    work = %{"root" => "/root"}
    snapshot = %{main: "main", head: "headtree", results: %{}}

    fake("")
    assert StaticReview.section(work, snapshot) == ""
  end
end
