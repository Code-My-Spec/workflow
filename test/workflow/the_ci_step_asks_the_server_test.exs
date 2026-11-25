defmodule Workflow.TheCiStepAsksTheServerTest do
  # Not async: the server, the command a checkout runs, the agent, and where
  # works in flight are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  # The server's ci endpoint, on loopback: each ask for a verdict is told to the
  # test and answered with what the test set in `answer`; anything else is a 404.
  defmodule FakeServer do
    import Plug.Conn

    def init(options), do: options

    def call(%{request_path: "/api/ci/" <> sha} = conn, %{test: test, answer: answer}) do
      send(test, {:asked, sha, get_req_header(conn, "authorization")})
      {status, reply} = Agent.get(answer, & &1)
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(reply))
    end

    def call(conn, _options), do: send_resp(conn, 404, "{}")
  end

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    test = self()

    was =
      for key <- [:cmd, :works_dir, :agents_run, :push, :server, :ci_interval],
          do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    # Git is real; `just` is never run, and passes.
    Application.put_env(:workflow, :cmd, fn
      "just", _args, _opts -> {"", 0}
      command, args, opts -> System.cmd(command, args, opts)
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    # No such remote: promote merges into the main copy and pushes nothing.
    Application.put_env(:workflow, :push, %{"remote" => "nowhere", "branch" => "main"})
    # Asked again every 20ms, not every minute.
    Application.put_env(:workflow, :ci_interval, 20)

    {:ok, answer} = Agent.start_link(fn -> {404, %{"error" => "no verdict yet"}} end)

    bandit =
      start_supervised!(
        {Bandit,
         plug: {FakeServer, %{test: test, answer: answer}},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    # The loop's own sign-in, as `workflow sign-in` writes it, in a state dir under tmp.
    state = Path.join(dir, "state")
    hash = :crypto.hash(:sha256, "http://127.0.0.1:#{port}") |> Base.encode16(case: :lower)
    File.mkdir_p!(state)

    File.write!(
      Path.join(state, "harness_oauth_#{hash}.json"),
      Jason.encode!(%{
        "access_token" => "loop-access",
        "refresh_token" => "loop-refresh",
        "expires_at" => System.system_time(:second) + 3600
      })
    )

    Application.put_env(:workflow, :server, %{
      "url" => "ws://127.0.0.1:#{port}/socket/websocket",
      "project_id" => "p",
      "state_dir" => state
    })

    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    git(main, ~w(init -q -b main))
    git(main, ~w(config user.name t))
    git(main, ~w(config user.email t@example.com))
    commit(main, "fix.txt", "broken\n", "first")

    root = Path.join(dir, "i1")
    git(main, ["worktree", "add", "-q", "-b", "issue/i1", root])
    commit(root, "fix.txt", "fixed\n", "issue i1: the fix")

    work = %{
      "kind" => "issue",
      "id" => "i1",
      "root" => root,
      "repo" => main,
      "agent" => %{"provider" => "claude-code"}
    }

    %{main: main, work: work, answer: answer, in_flight: Path.join([dir, "works", "i1.json"])}
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit(dir, file, content, message) do
    File.write!(Path.join(dir, file), content)
    git(dir, ["add", file])
    git(dir, ["commit", "-q", "-m", message])
  end

  # Through certify, review (passed) and promote, to wait at ci; the full sha
  # of the commit it landed as.
  defp land(work, main) do
    test = self()

    Application.put_env(:workflow, :agents_run, fn
      %{name: "review"}, _work ->
        {%{"status" => "pass"}, nil}

      step, _work ->
        send(test, {:agent, step.name, step.note})
        {%{}, nil}
    end)

    capture_log(fn ->
      assert {%{name: "certify"}, "started"} = Workflow.Run.start(work)
      Workflow.Settled.idle()
    end)

    assert %{step: "ci", actor: :external} = Workflow.Run.look(work)
    git(main, ~w(rev-parse HEAD))
  end

  # The poller runs on its own clock; what it did is waited for, generously.
  defp eventually(check, tries \\ 500) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("it never came to pass")
      true -> Process.sleep(20) && eventually(check, tries - 1)
    end
  end

  test "the-ci-step-asks-the-server: criterion 1 - a green answer for the landed commit releases the work waiting at ci",
       %{main: main, work: work, answer: answer, in_flight: file} do
    sha = land(work, main)
    assert_receive {:asked, ^sha, _auth}, 5_000

    Agent.update(answer, fn _ -> {200, %{"verdict" => "green"}} end)

    capture_log(fn ->
      eventually(fn -> not File.exists?(file) end)
      Workflow.Settled.idle()
    end)

    assert %{done: true} = Workflow.Run.look(work)
  end

  test "the-ci-step-asks-the-server: criterion 2 - a red answer sends the work back with the failing tests it names",
       %{main: main, work: work, answer: answer} do
    sha = land(work, main)
    assert_receive {:asked, ^sha, _auth}, 5_000

    Agent.update(answer, fn _ ->
      {200, %{"verdict" => "red", "commit" => sha, "failing" => ["test/a_test.exs:12"]}}
    end)

    capture_log(fn ->
      assert_receive {:agent, "fix", note}, 10_000
      assert note =~ "ci failed"
      assert note =~ "test/a_test.exs:12"
      Workflow.Settled.idle()
    end)
  end

  test "the-ci-step-asks-the-server: criterion 3 - a 404 leaves the work at ci, and the server is asked again",
       %{main: main, work: work, answer: answer, in_flight: file} do
    sha = land(work, main)
    assert_receive {:asked, ^sha, _auth}, 5_000
    assert_receive {:asked, ^sha, _auth}, 5_000

    assert %{step: "ci", done: false} = Workflow.Run.look(work)
    assert File.exists?(file)
    refute_received {:agent, _step, _note}

    # Let it end.
    Agent.update(answer, fn _ -> {200, %{"verdict" => "green"}} end)

    capture_log(fn ->
      eventually(fn -> not File.exists?(file) end)
      Workflow.Settled.idle()
    end)
  end

  test "the-ci-step-asks-the-server: criterion 4 - the ask names the landed commit's full sha and carries the loop's sign-in, as CloneToken sends it",
       %{main: main, work: work, answer: answer, in_flight: file} do
    sha = land(work, main)
    assert String.length(sha) == 40
    assert_receive {:asked, ^sha, ["Bearer loop-access"]}, 5_000

    Agent.update(answer, fn _ -> {200, %{"verdict" => "green"}} end)

    capture_log(fn ->
      eventually(fn -> not File.exists?(file) end)
      Workflow.Settled.idle()
    end)
  end
end
