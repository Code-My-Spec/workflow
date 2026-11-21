defmodule Workflow.Parts do
  @moduledoc """
  What a story and a journey share: built one part at a time. QA writes a
  failing test for the next untested part (`specify`), the system runs the
  tests (`run`), a coder makes them pass (`work`), the system merges and
  checks (`certify`), a reviewer passes or fails it (`review`), and the
  system merges it into the main copy (`promote`).

  Every function here is parameterised by the word for a part ("criterion"
  or "stage"), the key its list comes under in the work (`:criteria` or
  `:stages`), and the noun for the thing ("story" or "journey"), where they
  differ.
  """

  # The house style, said to everyone who writes and held to by the reviewer.
  @external_resource Path.join(:code.priv_dir(:workflow), "knowledge/ponytail.md")
  @lean File.read!(Path.join(:code.priv_dir(:workflow), "knowledge/ponytail.md"))

  # Said to those who check a page; the session is the work's own (AGENT_BROWSER_SESSION).
  @browser "When a part is a page someone uses, look at it in a browser with `agent-browser`: " <>
             "`agent-browser open <url>`, `agent-browser snapshot -i` for what is on the page and " <>
             "its refs, `agent-browser fill <ref> <text>`, `agent-browser click <ref>`, and " <>
             "`agent-browser eval <js>` for what a snapshot does not show.\n\n" <>
             "Nothing is running for you: start the app yourself in the same command as your " <>
             "browser steps, in the background with `&` and on a port of its own; wait until it " <>
             "answers, and kill it before the command ends. Your shell refuses `>` to a file, so " <>
             "use no redirection. For a Phoenix app, for example:\n\n" <>
             "    PORT=4123 mix phx.server & pid=$!; for i in $(seq 1 60); do curl -s -o /dev/null " <>
             "localhost:4123/ && break; sleep 1; done; agent-browser open http://localhost:4123/dogs; " <>
             "agent-browser eval '...'; agent-browser close; kill $pid; wait $pid\n\n"

  # Seen live: the other story files in the checkout (stories/*.yml) are readable,
  # and a coder built, and a reviewer judged by, a neighbouring story's criteria.
  defp own(noun),
    do:
      "Your work is this #{noun}'s criteria, as your first message gives them, and nothing " <>
        "from another story file: the other `stories/*.yml` in the checkout are other works', " <>
        "not yours to build or judge by.\n\n"

  def qa(word, noun) do
    %{
      tools: [:read, :edit, :write, :bash],
      decides: :may,
      decision:
        "Record that the code already meets the #{word}: pass, with a note saying it was " <>
          "already met and why. Commit a test for it first: it counts as met only when " <>
          "that test passes.",
      brief:
        "You write one test for the next #{word} of this #{noun} that has no test yet, " <>
          "with the text \"<id>: #{word} N\" in the test's name, and commit it with git. " <>
          "It must fail against the code as it stands. If the code already does what the " <>
          "#{word} asks, keep the honest test, commit it, and call `decide` with pass and " <>
          "why: never weaken or twist a test to make it fail.\n\n" <>
          own(noun) <> @browser <> @lean
    }
  end

  def coder(noun) do
    %{
      tools: [:read, :edit, :write, :bash],
      brief:
        "You are the coder on one #{noun} in this checkout. Make its failing tests pass, " <>
          "commit with git, then end your turn.\n\n" <> own(noun) <> @lean
    }
  end

  def reviewer(noun, key) do
    %{
      tools: [:read, :bash],
      decides: true,
      brief:
        "You review one #{noun} in this checkout, and change nothing. Read the diff since " <>
          "the branch you are told (`git diff <branch>...HEAD`). Does it meet its #{key}, " <>
          "does each have a test that fails without it, and does it keep to the rule its " <>
          "writers were given? Then call `decide` once: pass, or fail with a note saying " <>
          "what must change.\n\n" <> own(noun) <> @browser <> "The rule:\n\n" <> @lean
    }
  end

  # Nothing is named yet: send qa after the first part.
  def status(%{name: "specify"}, %{named: []} = snapshot, word, key, _noun),
    do: specify_note(1, snapshot, word, key)

  def status(%{name: "specify"}, snapshot, word, key, _noun) do
    case run(snapshot) do
      %{"status" => "passed"} ->
        # Fresh off specify and already green: the new test asserts nothing new,
        # unless qa said the code already meets the part.
        met? = found(snapshot, "specify")["status"] == "pass"

        cond do
          by(snapshot) == "specify" and not met? ->
            n = List.last(snapshot.named)

            %{
              note:
                "The test for #{word} #{n} passes already. Make it assert what is not built " <>
                  "yet, or, if the code already meets the #{word}, commit the test and call " <>
                  "`decide` with pass and why.",
              stage: n
            }

          # qa called the part already met but committed nothing, in this turn or an
          # earlier one on the branch: no test backs it.
          by(snapshot) == "specify" and met? and not committed?(snapshot) and
              List.last(snapshot.named) not in Map.get(snapshot, :committed, []) ->
            n = List.last(snapshot.named)

            %{
              note:
                "You called #{word} #{n} already met but committed no test. Write a test " <>
                  "for it, with the text \"#{snapshot.id}: #{word} #{n}\" in its name, " <>
                  "commit it with git, and call `decide` with pass and why.",
              stage: n
            }

          true ->
            case next_unnamed(snapshot, key) do
              nil -> :done
              n -> specify_note(n, snapshot, word, key)
            end
        end

      _not_passed_yet ->
        :done
    end
  end

  def status(%{name: "run"}, snapshot, _word, _key, _noun) do
    if run(snapshot), do: :done, else: %{}
  end

  def status(%{name: "work"}, snapshot, _word, _key, _noun) do
    case run(snapshot) do
      %{"status" => "failed", "note" => note} -> %{note: note}
      _passed_or_absent -> :done
    end
  end

  def status(%{name: "certify"}, snapshot, _word, _key, _noun) do
    case found(snapshot, "certify") do
      %{"status" => "passed"} -> :done
      %{"status" => "failed", "note" => note} -> {:to, "work", %{note: note}}
      nil -> %{}
    end
  end

  def status(%{name: "review"}, snapshot, _word, _key, noun) do
    case found(snapshot, "review") do
      %{"status" => "pass"} ->
        :done

      %{"status" => "fail", "note" => note} ->
        {:to, "work", %{note: "The review failed: #{note}"}}

      nil ->
        %{note: "Review the #{noun} against the branch `#{snapshot[:main]}`."}
    end
  end

  def status(%{name: "promote"}, snapshot, _word, _key, _noun) do
    case found(snapshot, "promote") do
      %{"status" => "promoted"} -> landed(snapshot, "work")
      %{"status" => "refused", "note" => note} -> {:to, "work", %{note: note}}
      %{"status" => "conflicted", "note" => note} -> {:to, "work", %{note: note, stop: true}}
      nil -> %{}
    end
  end

  @doc "A landing whose ci failed goes back to the `back` step with the ci note, as a failed certify does."
  def landed(snapshot, back) do
    case found(snapshot, "ci") do
      %{"status" => "failed", "note" => note} -> {:to, back, %{note: note}}
      _green_or_not_run -> :done
    end
  end

  def perform("run", %{"root" => root} = work, _snapshot),
    do: Workflow.Checkout.test(root, work["project"])

  def perform("certify", %{"root" => root} = work, snapshot),
    do: Workflow.Checkout.certify(root, snapshot, work["project"])

  def perform("promote", %{"root" => root}, snapshot),
    do: Workflow.Checkout.promote(root, snapshot)

  def observe(key, word, %{"id" => id} = work, snapshot) do
    %{named: named(work, id, word), id: id}
    |> Map.merge(committed(work, id, word, snapshot))
    |> Map.put(key, work[Atom.to_string(key)])
  end

  defp specify_note(n, snapshot, word, key) do
    parts = Map.fetch!(snapshot, key)

    %{
      note:
        "Write one test for #{word} #{n}, with the text \"#{snapshot.id}: #{word} #{n}\" " <>
          "in its name: #{inspect(Enum.at(parts, n - 1))}. It must fail against the code " <>
          "as it stands.",
      stage: n
    }
  end

  defp run(%{head: head, results: results}), do: get_in(results, [head, "run"])
  defp by(%{head: head, results: results}), do: get_in(results, [head, "by", "step"])

  # Whether the step that made the tree committed anything: the branch has more
  # commits than it had when that step began (none, if that was not kept).
  defp committed?(%{head: head, results: results} = snapshot) do
    from = get_in(results, [head, "by", "from"]) || 0
    Map.get(snapshot, :commits, 0) > from
  end

  def found(%{head: head, results: results}, step), do: get_in(results, [head, step])

  defp next_unnamed(snapshot, key) do
    parts = Map.fetch!(snapshot, key)
    Enum.find(1..length(parts)//1, &(&1 not in snapshot.named))
  end

  # No git: a part's tests are read straight off the tree that is checked out.
  defp named(%{"root" => root} = work, id, word) do
    dir = root |> Path.join(work["project"] || ".") |> Path.join("test")

    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.flat_map(&parts_in(&1, id, word))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parts_in(file, id, word), do: numbers(File.read!(file), id, word)

  defp numbers(text, id, word) do
    ~r/#{Regex.escape(id)}: #{word} (\d+)/
    |> Regex.scan(text)
    |> Enum.map(fn [_, n] -> String.to_integer(n) end)
  end

  # The parts whose test a commit on the branch since it was cut from main added,
  # whichever turn made it; none when that cannot be read, and nothing with no main branch.
  defp committed(%{"root" => root} = work, id, word, %{main: main}) when is_binary(main) do
    test = Path.join(work["project"] || ".", "test")
    args = ["log", "-p", "--no-merges", "--format=", "#{main}..HEAD", "--", test]

    with true <- File.dir?(root),
         {log, 0} <-
           Workflow.Checkout.cmd("git", args, [cd: root, stderr_to_stdout: true], &System.cmd/3) do
      added =
        log
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "+"))
        |> Enum.join("\n")

      %{committed: added |> numbers(id, word) |> Enum.uniq()}
    else
      _unread -> %{committed: []}
    end
  end

  defp committed(_work, _id, _word, _snapshot), do: %{}
end
