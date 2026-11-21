defmodule Workflow.MainCopyFollowsRemoteTest do
  use ExUnit.Case

  @moduletag :tmp_dir

  alias Workflow.Checkout

  defp git(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(out)
  end

  defp identify(dir) do
    git(dir, ["config", "user.name", "t"])
    git(dir, ["config", "user.email", "t@example.com"])
  end

  # A main copy pushing to a local bare remote's dev, a work cut from it, and
  # another writer's clone of the remote.
  defp setup_repos(dir) do
    remote = Path.join(dir, "remote.git")
    main = Path.join(dir, "main")
    other = Path.join(dir, "other")
    work = main <> "-w1"
    File.mkdir_p!(main)

    git(dir, ["init", "--bare", remote])
    git(main, ["init", "-b", "main"])
    identify(main)
    git(main, ["remote", "add", "origin", remote])
    File.write!(Path.join(main, "f.txt"), "one\n")
    git(main, ["add", "f.txt"])
    git(main, ["commit", "-m", "first"])
    git(main, ["push", "origin", "HEAD:dev"])
    git(dir, ["clone", "-b", "dev", remote, other])
    identify(other)
    git(main, ["worktree", "add", "-b", "issue/w1", work])

    %{remote: remote, main: main, other: other, work: work}
  end

  defp commit(dir, file, content, message) do
    File.write!(Path.join(dir, file), content)
    git(dir, ["add", file])
    git(dir, ["commit", "-m", message])
    git(dir, ["rev-parse", "HEAD"])
  end

  test "main-copy-follows-remote: criteria 1 and 2 - the remote gained a commit while the work ran: it lands and its push is accepted",
       %{tmp_dir: dir} do
    %{remote: remote, main: main, other: other, work: work} = setup_repos(dir)

    theirs = commit(other, "theirs.txt", "theirs\n", "another writer")
    git(other, ["push", "origin", "HEAD:dev"])
    ours = commit(work, "ours.txt", "ours\n", "the work")

    promoted = Checkout.promote(work, %{main_copy: main})

    assert %{"status" => "promoted"} = promoted
    refute Map.has_key?(promoted, "note")
    assert git(remote, ["rev-parse", "dev"]) == git(main, ["rev-parse", "HEAD"])
    assert git(remote, ["merge-base", "--is-ancestor", theirs, "dev"]) == ""
    assert git(remote, ["merge-base", "--is-ancestor", ours, "dev"]) == ""
  end

  test "main-copy-follows-remote: criterion 3 - the remote's new commit conflicts: the work stops, the manager is told git's output, nothing is pushed",
       %{tmp_dir: dir} do
    keys = [:manager, :works_dir, :recipients]
    was = for key <- keys, do: {key, Application.get_env(:workflow, key)}

    on_exit(fn ->
      for {key, value} <- was do
        if value,
          do: Application.put_env(:workflow, key, value),
          else: Application.delete_env(:workflow, key)
      end
    end)

    Application.put_env(:workflow, :works_dir, Path.join(dir, "works"))
    Application.put_env(:workflow, :manager, %{"repo" => "/nowhere/repo"})
    Application.delete_env(:workflow, :recipients)

    %{remote: remote, main: main, other: other, work: work} = setup_repos(dir)

    theirs = commit(other, "f.txt", "theirs\n", "another writer")
    git(other, ["push", "origin", "HEAD:dev"])
    commit(work, "f.txt", "ours\n", "the work")

    result = Checkout.promote(work, %{main_copy: main})

    assert %{"status" => "conflicted", "note" => note} = result
    assert note =~ "CONFLICT"
    assert git(remote, ["rev-parse", "dev"]) == theirs
    assert git(main, ["status", "--porcelain"]) == ""

    snapshot = %{head: "h", main: "main", results: %{"h" => %{"promote" => result}}}
    assert {:to, "fix", %{stop: true}} = Workflow.Issue.status(%{name: "promote"}, snapshot)

    told =
      Enum.find_value(1..40, [], fn _ ->
        case Workflow.Messages.unread("manager") do
          [] -> Process.sleep(50) && nil
          messages -> messages
        end
      end)

    assert [%{"text" => text}] = told
    assert text =~ "CONFLICT"
  end

  test "main-copy-follows-remote: criterion 3 - a main copy whose own commits conflict with the remote's stops, nothing pushed",
       %{tmp_dir: dir} do
    %{remote: remote, main: main, other: other, work: work} = setup_repos(dir)

    theirs = commit(other, "f.txt", "theirs\n", "another writer")
    git(other, ["push", "origin", "HEAD:dev"])
    commit(main, "f.txt", "main's\n", "the main copy's own")
    mains = git(main, ["rev-parse", "HEAD"])
    commit(work, "w.txt", "w\n", "the work")

    assert %{"status" => "conflicted", "note" => note} =
             Checkout.promote(work, %{main_copy: main})

    assert note =~ "CONFLICT"
    assert git(main, ["rev-parse", "HEAD"]) == mains
    assert git(remote, ["rev-parse", "dev"]) == theirs
  end
end
