defmodule Workflow.LoopRunsADevopsWorkTest do
  # Not async: the command a checkout runs, the plugin, the agent, the server's
  # line and where works in flight are kept, are app-wide.
  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias Workflow.Checkout

  # A fake bin/resolve.exs, shaped as the plugin's: one `step` event a line of
  # devops.yml whose tools/<concept>/<provider>/{apply,probe} are both there,
  # else one `refused` event a line naming it, `fail` and exit 1.
  @resolve ~S"""
  [path] = System.argv()
  root = Path.expand("..", __DIR__)

  resolved =
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> String.trim(line) == "" end)
    |> Enum.map(fn {line, n} ->
      [env, rest] = String.split(line, ":", parts: 2)
      [concept, provider | settings] = String.split(rest)
      dir = "tools/#{concept}/#{provider}"

      if File.regular?(Path.join(root, dir <> "/apply")) and File.regular?(Path.join(root, dir <> "/probe")) do
        {:step,
         %{"event" => "step", "id" => "#{env}/#{concept}/#{provider}", "environment" => env,
           "apply" => dir <> "/apply", "probe" => dir <> "/probe", "settings" => settings,
           "line" => n, "text" => line}}
      else
        {:refused,
         %{"event" => "refused", "line" => n, "text" => line,
           "message" => "line #{n} `#{line}` names #{concept} #{provider}, which has no script"}}
      end
    end)

  case for {:refused, e} <- resolved, do: e do
    [] ->
      for {:step, e} <- resolved, do: IO.puts(JSON.encode!(e))
      IO.puts(JSON.encode!(%{"event" => "pass"}))

    refused ->
      for e <- refused, do: IO.puts(JSON.encode!(e))
      IO.puts(JSON.encode!(%{"event" => "fail"}))
      System.halt(1)
  end
  """

  setup %{tmp_dir: dir} do
    Workflow.Tellings.quiet()
    on_exit(&Workflow.Tellings.quiet/0)

    was =
      for key <- [:cmd, :works_dir, :agents_run, :push, :server, :manager, :plugin],
          do: {key, Application.get_env(:workflow, key)}

    # Git and the scripts are real; `just` and agent-browser are never run, and pass.
    Application.put_env(:workflow, :cmd, fn
      command, _args, _opts when command in ["just", "agent-browser"] -> {"", 0}
      command, args, opts -> System.cmd(command, args, opts)
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :push, %{"remote" => "nowhere", "branch" => "main"})
    Application.put_env(:workflow, :server, %{"url" => "ws://x", "project_id" => "p1"})
    Application.delete_env(:workflow, :manager)

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    # The fake plugin: bin/resolve.exs, the devops skill, and three providers.
    plugin = Path.join(dir, "plugin")
    calls = Path.join(dir, "calls.log")
    File.mkdir_p!(Path.join(plugin, "bin"))
    File.write!(Path.join([plugin, "bin", "resolve.exs"]), @resolve)
    File.mkdir_p!(Path.join([plugin, "skills", "devops"]))

    File.write!(
      Path.join([plugin, "skills", "devops", "SKILL.md"]),
      "---\nname: devops\ndescription: DevOps as tools.\n---\n\n# DevOps\n"
    )

    script(plugin, calls, "dns/fake", "apply", 0, nil)
    script(plugin, calls, "dns/fake", "probe", 0, nil)
    script(plugin, calls, "mail/fake", "apply", 0, nil)
    script(plugin, calls, "mail/fake", "probe", 0, nil)
    # Its apply says it passed; its probe, the truth, fails with the provider's words.
    script(plugin, calls, "dns/broken", "apply", 0, nil)
    script(plugin, calls, "dns/broken", "probe", 1, "Cloudflare: zone example.com not found")
    Application.put_env(:workflow, :plugin, plugin)

    main = Path.join(dir, "main")
    File.mkdir_p!(main)
    git(main, ~w(init -q -b main))
    git(main, ~w(config user.name t))
    git(main, ~w(config user.email t@example.com))

    work = %{
      "kind" => "devops",
      "id" => "d1",
      "repo" => main,
      "action" => "apply",
      "environment" => "uat",
      "agent" => %{"provider" => "claude-code"}
    }

    stand_in()
    %{main: main, plugin: plugin, calls: calls, work: work}
  end

  # A tool script that logs its call, prints two events and exits `code`.
  defp script(plugin, calls, tool, name, code, words) do
    path = Path.join([plugin, "tools", tool, name])
    File.mkdir_p!(Path.dirname(path))

    last =
      if code == 0,
        do: ~s({"event":"pass"}),
        else: ~s({"event":"fail","message":"#{words}"})

    File.write!(path, """
    #!/bin/sh
    echo "#{tool} #{name} $*" >> "$(dirname "$0")/../../../../#{Path.basename(calls)}"
    echo '{"event":"start","tool":"#{tool}"}'
    echo '#{last}'
    exit #{code}
    """)

    File.chmod!(path, 0o755)
  end

  defp devops_yml(main, text) do
    File.write!(Path.join(main, "devops.yml"), text)
    git(main, ~w(add devops.yml))
    git(main, ["commit", "-q", "-m", "devops.yml"])
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  # A fake server line: each report it is handed is told the test as pushed.
  defp stand_in do
    test = self()
    pid = spawn_link(fn -> forward(test) end)
    Process.register(pid, Workflow.Server)
  end

  defp forward(test) do
    receive do
      {:report, report} ->
        send(test, {:pushed, report})
        forward(test)
    end
  end

  defp pushed(acc \\ []) do
    receive do
      {:pushed, %{"work" => "d1"} = report} -> pushed([report | acc])
      {:pushed, _other} -> pushed(acc)
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp calls(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp run(work) do
    capture_log(fn ->
      assert {_step, "started"} = Workflow.Run.start(work)
      Workflow.Settled.idle()
    end)
  end

  test "loop-runs-a-devops-work: criterion 1 - a devops.yml with a line that resolves to no script is refused at hand-in, naming each such line, and nothing runs",
       %{main: main, calls: calls, work: work} do
    devops_yml(main, "uat: dns fake zone=example.com\nuat: dns nowhere\nuat: mail gone\n")

    manager = %{"repo" => main, "agent" => %{"provider" => "claude-code"}}
    hand_in = Enum.find(Workflow.Manager.tools(manager), &(&1.name == "hand_in"))
    input = Map.take(work, ["kind", "id", "action", "environment"])

    {:ok, said} = capture_log_result(fn -> hand_in.execute.(input, %{}) end)

    assert said =~ "Refused"
    assert said =~ "line 2 `uat: dns nowhere`"
    assert said =~ "line 3 `uat: mail gone`"
    refute said =~ "line 1"
    assert calls(calls) == []
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []
    refute File.dir?(Checkout.root(main, "d1"))
  end

  test "loop-runs-a-devops-work: criterion 1 - a work whose devops.yml goes bad in its copy stops at resolve, naming the line, and runs no script",
       %{main: main, calls: calls, work: work} do
    devops_yml(main, "uat: dns nowhere\n")

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      flunk("no #{step.name} turn")
    end)

    run(work)

    assert calls(calls) == []
    assert %{"step" => "resolve", "reason" => reason} = Checkout.stopped(main, "d1")
    assert reason =~ "line 1 `uat: dns nowhere`"
  end

  test "loop-runs-a-devops-work: criterion 2 - an apply work runs each step apply then its probe, as system steps, and is done when every probe passes",
       %{main: main, calls: calls, work: work} do
    devops_yml(main, "uat: dns fake zone=example.com\nprod: dns broken\nuat: mail fake\n")

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      flunk("no #{step.name} turn")
    end)

    run(work)

    # Only uat's lines, in file order, each apply then its probe.
    assert calls(calls) == [
             "dns/fake apply uat zone=example.com",
             "dns/fake probe uat zone=example.com",
             "mail/fake apply uat",
             "mail/fake probe uat"
           ]

    reports = pushed()
    assert %{"status" => "done", "kind" => "devops"} = List.last(reports)
    assert Path.wildcard(Path.join(Workflow.Run.works_dir(), "*.json")) == []
  end

  test "loop-runs-a-devops-work: criterion 2 - a check work runs only the probes",
       %{main: main, calls: calls, work: work} do
    devops_yml(main, "uat: dns fake\n")

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      flunk("no #{step.name} turn")
    end)

    run(Map.put(work, "action", "check"))

    assert calls(calls) == ["dns/fake probe uat"]
  end

  test "loop-runs-a-devops-work: criterion 3 - a failed probe goes to the coder with the provider words and the devops skill, is probed again after each turn, and once the retries are spent the work waits on a person",
       %{main: main, plugin: plugin, calls: calls, work: work} do
    devops_yml(main, "uat: dns broken\n")
    test = self()

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      send(test, {:agent, step.name, step.actor, step.note, step.agent[:skills]})
      {%{"said" => "looked at the zone"}, nil}
    end)

    run(work)

    retries = Workflow.Devops.retries()
    assert retries == 3

    # Applied once; probed first and again after each of the coder's turns.
    assert calls(calls) ==
             ["dns/broken apply uat"] ++ List.duplicate("dns/broken probe uat", retries + 1)

    skill = Path.join([plugin, "skills", "devops"])

    for _try <- 1..retries do
      assert_received {:agent, "fix", :coder, note, skills}
      assert note =~ "Cloudflare: zone example.com not found"
      assert skill in skills
    end

    refute_received {:agent, _, _, _, _}

    root = Checkout.root(main, "d1")

    assert %{step: "person", actor: :owner} =
             Workflow.Run.look(%{"kind" => "devops", "id" => "d1", "root" => root})

    assert %{"reason" => "waiting on its owner" <> _ = reason} = Checkout.stopped(main, "d1")
    assert reason =~ "Cloudflare: zone example.com not found"

    assert %{"status" => "waiting on a person"} =
             Workflow.Report.of(root, "d1")
  end

  test "loop-runs-a-devops-work: criterion 4 - every event a step script writes reaches the server as one of the work reports",
       %{main: main, work: work} do
    devops_yml(main, "uat: dns fake\nuat: mail fake\n")

    Application.put_env(:workflow, :agents_run, fn step, _work ->
      flunk("no #{step.name} turn")
    end)

    run(work)

    events =
      for %{"event" => %{} = event} = report <- pushed(),
          event["phase"] in ["apply", "probe"] do
        assert %{"kind" => "devops", "work" => "d1", "project" => "p1"} = report
        {event["step"], event["phase"], event["event"]}
      end

    assert events == [
             {"uat/dns/fake", "apply", "start"},
             {"uat/dns/fake", "apply", "pass"},
             {"uat/dns/fake", "probe", "start"},
             {"uat/dns/fake", "probe", "pass"},
             {"uat/mail/fake", "apply", "start"},
             {"uat/mail/fake", "apply", "pass"},
             {"uat/mail/fake", "probe", "start"},
             {"uat/mail/fake", "probe", "pass"}
           ]
  end

  defp capture_log_result(fun) do
    ref = make_ref()
    capture_log(fn -> send(self(), {ref, fun.()}) end)
    receive do: ({^ref, result} -> result)
  end
end
