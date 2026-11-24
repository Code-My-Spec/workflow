defmodule Workflow.LoopClonesHostedReposTest do
  # Not async: the server, the command runner and the push target are the application's.
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Workflow.Checkout

  @moduletag :tmp_dir

  # The server's clone_token endpoint, on loopback: each request is told to the
  # test and answered from a script; the last answer repeats.
  defmodule FakeServer do
    import Plug.Conn

    def init(options), do: options

    def call(conn, %{test: test, answers: answers}) do
      {:ok, body, conn} = read_body(conn)

      send(
        test,
        {:asked, conn.request_path, get_req_header(conn, "authorization"), Jason.decode!(body)}
      )

      {status, reply} =
        Agent.get_and_update(answers, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(reply))
    end
  end

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    keys = [:server, :cmd, :push, :manager]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end

      Workflow.Tellings.quiet()
    end)

    Application.delete_env(:workflow, :push)
    Application.delete_env(:workflow, :manager)

    {:ok, answers} = Agent.start_link(fn -> [{404, %{"error" => "not_hosted"}}] end)
    test = self()

    bandit =
      start_supervised!(
        {Bandit,
         plug: {FakeServer, %{test: test, answers: answers}},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    # The loop's own sign-in, as `workflow sign-in` writes it, in a state dir under tmp.
    state = Path.join(dir, "state")

    server = %{
      "url" => "ws://127.0.0.1:#{port}/socket/websocket",
      "project_id" => "p",
      "state_dir" => state
    }

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

    Application.put_env(:workflow, :server, server)

    # Every git command the loop runs, told to the test with the env it was given.
    Application.put_env(:workflow, :cmd, fn command, args, opts ->
      if command == "git", do: send(test, {:git, args, Keyword.get(opts, :env, [])})
      System.cmd(command, args, opts)
    end)

    %{answers: answers}
  end

  defp git(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(out)
  end

  # A main copy pushing to a local bare remote's dev, and a work cut from it.
  defp repos(dir) do
    remote = Path.join(dir, "remote.git")
    main = Path.join(dir, "main")
    work = main <> "-w1"
    File.mkdir_p!(main)
    git(dir, ["init", "-q", "--bare", "-b", "main", remote])
    git(main, ["init", "-q", "-b", "main"])
    git(main, ["config", "user.name", "t"])
    git(main, ["config", "user.email", "t@example.com"])
    git(main, ["remote", "add", "origin", remote])
    File.write!(Path.join(main, "f.txt"), "one\n")
    git(main, ["add", "f.txt"])
    git(main, ["commit", "-q", "-m", "first"])
    git(main, ["push", "-q", "origin", "HEAD:main", "HEAD:dev"])
    git(main, ["worktree", "add", "-q", "-b", "issue/w1", work])
    File.write!(Path.join(work, "w.txt"), "work\n")
    git(work, ["add", "w.txt"])
    git(work, ["commit", "-q", "-m", "the work"])
    %{remote: remote, main: main, work: work}
  end

  defp hosted(token, expires_at, clone_url),
    do: {200, %{"token" => token, "expires_at" => expires_at, "clone_url" => clone_url}}

  defp header(token), do: "Authorization: Basic " <> Base.encode64("x-access-token:" <> token)

  defp asked do
    receive do
      {:asked, path, auth, body} -> [{path, auth, body} | asked()]
    after
      0 -> []
    end
  end

  # The git commands run so far whose first word is one of `verbs`, with their env.
  defp gits(verbs) do
    receive do
      {:git, [verb | _] = args, env} ->
        if verb in verbs, do: [{args, env} | gits(verbs)], else: gits(verbs)
    after
      0 -> []
    end
  end

  defp git_config(env), do: for({"GIT_CONFIG" <> _ = name, value} <- env, do: {name, value})

  defp in_files?(dir, secret) do
    Path.wildcard(Path.join(dir, "**"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.any?(&String.contains?(File.read!(&1), secret))
  end

  test "loop-clones-hosted-repos-with-a-clone-token: criteria 1 and 2 - a hosted repo's fetch and push carry the token through http.extraHeader, and it is in no remote URL, file or log line",
       %{tmp_dir: dir, answers: answers} do
    %{remote: remote, main: main, work: work} = repos(dir)
    secret = "clone-secret-1"

    Agent.update(answers, fn _ -> [hosted(secret, System.system_time(:second) + 3600, remote)] end)

    log =
      capture_log(fn ->
        assert {:ok, _sha} = Checkout.pinned(main, nil)
        assert %{"status" => "promoted"} = promoted = Checkout.promote(work, %{main_copy: main})
        refute Map.has_key?(promoted, "note")
      end)

    # Asked once, with the loop's bearer token and its project; reused after.
    assert [{"/api/repo/clone_token", ["Bearer loop-access"], %{"project_id" => "p"}}] = asked()

    remote_gits =
      gits(["fetch", "remote", "push"])
      |> Enum.reject(fn {args, _env} ->
        hd(args) == "remote" and args != ["remote", "update", "origin"]
      end)

    assert [["fetch" | _], ["remote", "update", "origin"], ["push", "origin", "HEAD:dev"]] =
             Enum.map(remote_gits, &elem(&1, 0))

    for {_args, env} <- remote_gits do
      assert [
               {"GIT_CONFIG_COUNT", "1"},
               {"GIT_CONFIG_KEY_0", "http.extraHeader"},
               {"GIT_CONFIG_VALUE_0", header(secret)}
             ] ==
               Enum.sort(git_config(env))
    end

    assert git(remote, ["rev-parse", "dev"]) == git(main, ["rev-parse", "HEAD"])

    for leak <- [secret, Base.encode64("x-access-token:" <> secret)] do
      refute git(main, ["remote", "-v"]) =~ leak
      refute in_files?(dir, leak)
      refute in_files?(Workflow.Run.works_dir(), leak)
      refute log =~ leak
    end
  end

  test "loop-clones-hosted-repos-with-a-clone-token: criterion 4 - a refusal leaves git exactly as today, and is kept so a second fetch asks nothing",
       %{tmp_dir: dir} do
    %{main: main, work: work} = repos(dir)

    assert {:ok, _sha} = Checkout.pinned(main, nil)
    assert {:ok, _sha} = Checkout.pinned(main, nil)
    assert %{"status" => "promoted"} = Checkout.promote(work, %{main_copy: main})

    assert [{"/api/repo/clone_token", _, _}] = asked()
    remote_gits = gits(["fetch", "push"])

    assert [
             ["fetch", "--all", "--quiet"],
             ["fetch", "--all", "--quiet"],
             ["push", "origin", "HEAD:dev"]
           ] ==
             Enum.map(remote_gits, &elem(&1, 0))

    for {_args, env} <- remote_gits, do: assert(git_config(env) == [])
  end

  test "loop-clones-hosted-repos-with-a-clone-token: criterion 3 - a token near its expires_at is refreshed, a valid one is reused",
       %{tmp_dir: dir, answers: answers} do
    %{remote: remote, main: main} = repos(dir)
    now = System.system_time(:second)

    Agent.update(answers, fn _ ->
      [
        hosted("near-expiry", now + 60, remote),
        hosted("fresh", DateTime.from_unix!(now + 3600) |> DateTime.to_iso8601(), remote)
      ]
    end)

    for _ <- 1..3, do: assert({:ok, _sha} = Checkout.pinned(main, nil))

    # The first token was near expiry, so the second fetch asked again; the third reused.
    assert length(asked()) == 2

    assert [header("near-expiry"), header("fresh"), header("fresh")] ==
             for({_args, env} <- gits(["fetch"]), do: Map.new(env)["GIT_CONFIG_VALUE_0"])
  end

  test "loop-clones-hosted-repos-with-a-clone-token: a hosted repo whose token cannot be had fails its push with one line naming no token",
       %{tmp_dir: dir, answers: answers} do
    %{remote: remote, main: main, work: work} = repos(dir)
    now = System.system_time(:second)
    Agent.update(answers, fn _ -> [hosted("near-expiry", now + 60, remote), {500, %{}}] end)

    assert {:ok, _sha} = Checkout.pinned(main, nil)
    assert %{"status" => "promoted", "note" => note} = Checkout.promote(work, %{main_copy: main})

    assert note =~
             "the push to origin dev failed: No clone token for project p from http://127.0.0.1:"

    assert note =~ "the server answered 500"
    refute note =~ "near-expiry"
  end

  test "loop-clones-hosted-repos-with-a-clone-token: with no main checkout yet, the loop clones from clone_url with the token",
       %{tmp_dir: dir, answers: answers} do
    %{remote: remote} = repos(dir)
    secret = "clone-secret-2"

    Agent.update(answers, fn _ -> [hosted(secret, System.system_time(:second) + 3600, remote)] end)

    fresh = Path.join([dir, "boxes", "project"])

    assert %{folder: folder, branch: "main"} = Checkout.landing(fresh)
    assert Path.expand(folder) |> String.ends_with?("boxes/project")

    assert [{["clone", "--quiet", ^remote, ^fresh], env}] = gits(["clone"])
    assert Map.new(env)["GIT_CONFIG_VALUE_0"] == header(secret)
    assert git(fresh, ["remote", "get-url", "origin"]) == remote
    refute in_files?(fresh, secret)
    refute in_files?(fresh, Base.encode64("x-access-token:" <> secret))
  end
end
