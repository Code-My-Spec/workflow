defmodule Workflow.EvidenceUploadTest do
  # Not async: the command a checkout runs, the server and the http are set for the whole application.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias Workflow.Checkout

  # A repository with one commit holding stories/j1.yml, by real git.
  defp repo(dir) do
    main = Path.join(dir, "main")
    File.mkdir_p!(Path.join(main, "stories"))

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: main, stderr_to_stdout: true)
      String.trim(out)
    end

    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.name", "t"])
    git.(["config", "user.email", "t@example.com"])
    File.write!(Path.join(main, "stories/j1.yml"), "id: j1\n")
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "first"])
    {main, git.(["rev-parse", "HEAD"])}
  end

  # Real git; a ci recipe that writes `evidence` (%{journey => [file]}) into its dir and exits `exit`.
  defp stand_in(evidence, exit \\ 0) do
    Application.put_env(:workflow, :cmd, fn
      "git", args, opts ->
        System.cmd("git", args, opts)

      "just", ["--show", "ci"], _opts ->
        {"ci dir:", 0}

      "just", ["--show", "retry"], _opts ->
        {"error: Justfile does not contain recipe `retry`", 1}

      "just", ["ci", target], _opts ->
        for {journey, files} <- evidence, file <- files do
          folder = Path.join([target, "evidence", journey])
          File.mkdir_p!(folder)
          File.write!(Path.join(folder, file), "bytes of #{file}")
        end

        {"", exit}
    end)

    on_exit(fn -> Application.delete_env(:workflow, :cmd) end)
  end

  # A server with a signed-in credential, and an http that tells the test every
  # request and answers by `answer`.
  defp server(dir, answer) do
    url = "wss://loop.example/socket/websocket"
    state = Path.join(dir, "state")
    File.mkdir_p!(state)
    hash = :crypto.hash(:sha256, Workflow.SignIn.base(url)) |> Base.encode16(case: :lower)

    File.write!(
      Path.join(state, "harness_oauth_#{hash}.json"),
      Jason.encode!(%{
        "access_token" => "tok",
        "expires_at" => System.system_time(:second) + 3600
      })
    )

    Application.put_env(:workflow, :server, %{
      "url" => url,
      "project_id" => "p1",
      "state_dir" => state
    })

    test = self()

    Application.put_env(:workflow, :evidence_http, fn method, url, opts ->
      send(test, {method, url, opts})
      answer.(method, url, opts)
    end)

    on_exit(fn ->
      Application.delete_env(:workflow, :server)
      Application.delete_env(:workflow, :evidence_http)
    end)
  end

  defp answers(method, _url, opts) do
    case method do
      :post ->
        files = opts[:json]["files"]

        {:ok, 200,
         %{"folder" => "f1", "puts" => Map.new(files, &{&1, "https://put.example/" <> &1})}}

      :put ->
        {:ok, 200, ""}
    end
  end

  test "evidence-folder-upload: criteria 1 and 2, a green ci with a server posts each journey and puts its pngs and story",
       %{tmp_dir: dir} do
    {main, commit} = repo(dir)
    stand_in(%{"j1" => ["b.png", "a.png", "notes.txt"], "j2" => ["x.png"]})
    server(dir, &answers/3)

    assert Checkout.ci(main, commit, nil) == :green

    assert_received {:post, "https://loop.example/api/loop/evidence", post}
    assert post[:auth] == {:bearer, "tok"}

    assert post[:json] == %{
             "project_id" => "p1",
             "commit" => commit,
             "journey" => "j1",
             "files" => ["a.png", "b.png", "j1.yml"]
           }

    assert_received {:put, "https://put.example/a.png", put_a}
    assert put_a[:body] == "bytes of a.png"
    assert_received {:put, "https://put.example/b.png", _}
    assert_received {:put, "https://put.example/j1.yml", put_yml}
    assert put_yml[:body] == "id: j1\n"

    # j2 has no story file in the checkout: its pngs only.
    assert_received {:post, _url, j2}
    assert j2[:json]["journey"] == "j2"
    assert j2[:json]["files"] == ["x.png"]
    assert_received {:put, "https://put.example/x.png", _}
    refute_received {:put, "https://put.example/notes.txt", _}
  end

  test "evidence-folder-upload: criterion 3, no evidence folder or no png sends nothing and logs no fault",
       %{tmp_dir: dir} do
    {main, commit} = repo(dir)
    server(dir, &answers/3)

    for evidence <- [%{}, %{"j1" => ["notes.txt"]}] do
      stand_in(evidence)
      File.rm_rf!(Path.join([main, ".git", "workflow", "analysis"]))

      log = capture_log(fn -> assert Checkout.ci(main, commit, nil) == :green end)

      refute_received {_method, _url, _opts}
      refute log =~ "[warning]"
      refute log =~ "[error]"
    end
  end

  test "evidence-folder-upload: criterion 4, a failing post or put logs one warning and leaves ci green",
       %{tmp_dir: dir} do
    {main, commit} = repo(dir)
    stand_in(%{"j1" => ["a.png", "b.png"]})

    for failing <- [:post, :put] do
      File.rm_rf!(Path.join([main, ".git", "workflow", "analysis"]))

      server(dir, fn
        ^failing, _url, _opts -> {:ok, 500, %{}}
        method, url, opts -> answers(method, url, opts)
      end)

      log = capture_log(fn -> assert Checkout.ci(main, commit, nil) == :green end)

      assert length(Regex.scan(~r/\[warning\]/, log)) == 1
      assert log =~ "evidence"
      refute log =~ "tok"
    end
  end

  test "evidence-folder-upload: a red ci or no server sends nothing", %{tmp_dir: dir} do
    {main, commit} = repo(dir)
    server(dir, &answers/3)
    stand_in(%{"j1" => ["a.png"]}, 1)
    refute Checkout.ci(main, commit, nil) == :green
    refute_received {_method, _url, _opts}

    File.rm_rf!(Path.join([main, ".git", "workflow", "analysis"]))
    Application.delete_env(:workflow, :server)
    stand_in(%{"j1" => ["a.png"]})
    assert Checkout.ci(main, commit, nil) == :green
    refute_received {_method, _url, _opts}
  end

  test "evidence-folder-upload: criterion 5, the README documents the evidence folder contract" do
    readme = File.read!(Path.join(__DIR__, "../../README.md"))
    assert readme =~ "<dir>/evidence/<journey id>/"
    assert readme =~ "/api/loop/evidence"
    assert readme =~ "stories/<journey id>.yml"
  end
end
