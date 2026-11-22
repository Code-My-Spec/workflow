defmodule Workflow.StoryFile do
  @moduledoc """
  A story or journey handed in, kept in the repository as `stories/<id>.yml`
  (inside the work's project directory when it names one), so it merges with
  the code that meets it. An issue handed in is kept as `issues/<id>.yml` in the
  main copy (see `issue_path/1`).

  The YAML is written by hand, to be read and diffed by a person: the text is a
  literal block, and each criterion (a journey's stage) is a line of its own.

  A story handed in with its rules (title, workflow, story, rules with their
  scenarios, questions) is written in that shape instead, holding what the
  person meant and nothing about process.
  """

  @shape ["title", "workflow", "story", "rules", "questions"]

  @doc "Where the work's file goes, relative to its checkout, or nil for a work that gets none."
  @spec path(map()) :: String.t() | nil
  def path(%{"kind" => kind, "id" => id} = work) when kind in ["story", "journey"] do
    # Only a work handed in with what it says. One handed in again with a review or
    # an owner's decision is not: its file would be written over with whatever came
    # with the decision, and committed on top of a tree already reviewed.
    cond do
      Enum.any?(["review", "demo"], &Map.has_key?(work, &1)) -> nil
      # Built from its file recorded in the main copy: that file is the work's already.
      work["recorded"] == true -> nil
      not Enum.any?(["text", "criteria", "stages" | @shape], &Map.has_key?(work, &1)) -> nil
      true -> in_project(work, "stories", id)
    end
  end

  def path(_work), do: nil

  @doc "Where an issue handed in is kept in the main copy: its project's `issues/<id>.yml`."
  @spec issue_path(map()) :: String.t()
  def issue_path(%{"kind" => "issue", "id" => id} = work),
    do: in_project(work, "issues", id)

  defp in_project(work, dir, name) do
    if work["project"] in [nil, "", "."],
      do: Path.join(dir, "#{name}.yml"),
      else: Path.join([work["project"], dir, "#{name}.yml"])
  end

  @doc """
  The story recorded for the work's id in `root` (its project's
  `stories/<id>.yml`), read back into the fields `yaml/1` writes in a story's
  shape; `{:none, path}` when there is no such file.
  """
  @spec recorded(map(), String.t()) :: {:ok, map()} | {:none, String.t()}
  def recorded(%{"id" => id} = work, root) do
    path = in_project(work, "stories", id)

    case File.read(Path.join(root, path)) do
      {:ok, yml} -> {:ok, yml |> String.split("\n") |> read_fields(%{})}
      {:error, _none} -> {:none, path}
    end
  end

  # Only the shape written here: top-level keys, each with its value on the line
  # or in the indented lines under it.
  defp read_fields([], fields), do: fields

  defp read_fields([line | rest], fields) do
    case Regex.run(~r/^([a-z]+):(.*)$/, line) do
      [_, key, value] ->
        {body, rest} = Enum.split_while(rest, &(&1 == "" or String.starts_with?(&1, " ")))
        body = body |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
        read_fields(rest, Map.put(fields, key, read_value(key, String.trim(value), body)))

      nil ->
        read_fields(rest, fields)
    end
  end

  defp read_value("rules", "", body), do: read_rules(body)

  defp read_value(_key, "", body) do
    for line <- body, [_, item] <- [Regex.run(~r/^  - (.*)$/, line)], do: read_scalar(item)
  end

  defp read_value(_key, ">", body), do: Enum.map_join(body, " ", &unindent/1)

  defp read_value(_key, "|" <> mode, body) do
    text = Enum.map_join(body, "\n", &unindent/1)
    if String.contains?(mode, "-"), do: text, else: text <> "\n"
  end

  defp read_value(_key, "[]", _body), do: []
  defp read_value(_key, value, _body), do: read_scalar(value)

  defp unindent("  " <> line), do: line
  defp unindent(line), do: line

  defp read_rules(body) do
    body
    |> Enum.reduce([], fn line, rules ->
      cond do
        match = Regex.run(~r/^  - rule: (.*)$/, line) ->
          [%{"rule" => read_scalar(Enum.at(match, 1)), "scenarios" => []} | rules]

        (match = Regex.run(~r/^      - (.*)$/, line)) && rules != [] ->
          [rule | others] = rules
          scenario = read_scenario(Enum.at(match, 1))
          [Map.update!(rule, "scenarios", &(&1 ++ [scenario])) | others]

        true ->
          rules
      end
    end)
    |> Enum.reverse()
  end

  defp read_scenario("\"" <> _ = text), do: read_scalar(text)

  defp read_scenario(text) do
    case Regex.run(~r/^([A-Za-z_]+): (.*)$/, text) do
      [_, kind, said] -> %{kind => read_scalar(said)}
      nil -> text
    end
  end

  # Quoted values were written as JSON; plain ones are the text itself.
  defp read_scalar("\"" <> _ = text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      _not_json -> text
    end
  end

  defp read_scalar(text), do: text

  @doc """
  The story's workflow file, `workflows/<workflow>.yml` beside its stories (the
  name lower-cased, each run of other than letters and digits one hyphen), as
  `[{path, content}]`: its name and the ids of its stories in order, this one
  added last unless it is there already. `[]` for a work that names no workflow.
  """
  @spec workflow_file(map(), String.t()) :: [{String.t(), String.t()}]
  def workflow_file(%{"kind" => "story", "id" => id, "workflow" => name} = work, root)
      when is_binary(name) do
    file = Regex.replace(~r/[^a-z0-9]+/, String.downcase(name), "-")

    if String.match?(file, ~r/[a-z0-9]/) do
      path = in_project(work, "workflows", file)

      ids =
        case File.read(Path.join(root, path)) do
          {:ok, yml} -> workflow_ids(yml)
          {:error, _none} -> []
        end

      ids = if id in ids, do: ids, else: ids ++ [id]

      [{path, IO.iodata_to_binary(["name: ", plain(name), "\nstories:", plain_list(ids, "  ")])}]
    else
      []
    end
  end

  def workflow_file(_work, _root), do: []

  defp workflow_ids(yml) do
    ~r/^  - (.+)$/m
    |> Regex.scan(yml)
    |> Enum.map(fn [_, id] ->
      case Jason.decode(id) do
        {:ok, decoded} when is_binary(decoded) -> decoded
        _plain -> id
      end
    end)
  end

  @doc """
  A story's criteria: those it was handed in with, or else one per scenario, in
  order, each its rule followed by the scenario's text.
  """
  @spec criteria(map()) :: list() | nil
  def criteria(%{"criteria" => criteria}) when is_list(criteria), do: criteria

  def criteria(%{"rules" => rules}) when is_list(rules) do
    for rule <- rules, scenario <- List.wrap(rule["scenarios"]) do
      Enum.join([rule["rule"], scenario_text(scenario)] |> Enum.reject(&(&1 in [nil, ""])), " ")
    end
  end

  def criteria(work), do: work["criteria"]

  defp scenario_text(scenario) when is_map(scenario) do
    scenario |> Map.values() |> Enum.map(&to_string/1) |> Enum.join(" ")
  end

  defp scenario_text(scenario), do: to_string(scenario)

  @doc "The work as YAML: in the story's shape when handed in with it, else its id, kind, text and criteria (a journey's stages)."
  @spec yaml(map()) :: String.t()
  def yaml(%{"kind" => "story"} = work)
      when is_map_key(work, "rules") or is_map_key(work, "story") or is_map_key(work, "title") do
    IO.iodata_to_binary([
      field(work, "title", &[" ", plain(&1), "\n"]),
      field(work, "workflow", &[" ", plain(&1), "\n"]),
      field(work, "story", &folded/1),
      field(work, "rules", &rules/1),
      field(work, "questions", &plain_list(&1, "  "))
    ])
  end

  def yaml(%{"kind" => kind, "id" => id} = work) do
    key = if kind == "journey", do: "stages", else: "criteria"

    IO.iodata_to_binary([
      "id: ",
      scalar(id),
      "\nkind: ",
      scalar(kind),
      "\n",
      field(work, "title", &[" ", plain(&1), "\n"]),
      "text:",
      block(work["text"]),
      key,
      ":",
      list(work[key])
    ])
  end

  defp field(work, key, write) do
    case Map.fetch(work, key) do
      {:ok, value} when value not in [nil, "", []] -> [key, ":", write.(value)]
      _absent -> []
    end
  end

  # One line of plain text: folded, as a person would write it.
  defp folded(text) when is_binary(text) do
    if String.contains?(text, "\n") or String.starts_with?(text, " ") or
         text != String.trim_trailing(text),
       do: block(text),
       else: [" >\n  ", text, "\n"]
  end

  defp folded(other), do: [" ", scalar(other), "\n"]

  defp rules(rules) when is_list(rules) do
    [
      "\n",
      Enum.map(rules, fn rule ->
        [
          "  - rule: ",
          plain(rule["rule"]),
          "\n",
          case List.wrap(rule["scenarios"]) do
            [] ->
              []

            scenarios ->
              ["    scenarios:\n", Enum.map(scenarios, &scenario/1)]
          end
        ]
      end)
    ]
  end

  defp rules(other), do: [" ", scalar(other), "\n"]

  defp scenario(scenario) when is_map(scenario) do
    Enum.map(scenario, fn {kind, text} -> ["      - ", plain(kind), ": ", plain(text), "\n"] end)
  end

  defp scenario(text), do: ["      - ", plain(text), "\n"]

  defp plain_list(items, indent) when is_list(items),
    do: ["\n", Enum.map(items, &[indent, "- ", plain(&1), "\n"])]

  defp plain_list(other, _indent), do: [" ", scalar(other), "\n"]

  # Plain when YAML would read it back as the same string, else quoted.
  defp plain(text) when is_binary(text) do
    if plain?(text), do: text, else: scalar(text)
  end

  defp plain(other), do: scalar(other)

  defp plain?(text) do
    text != "" and text == String.trim(text) and
      not String.contains?(text, ["\n", ": ", " #", "\t"]) and
      not String.ends_with?(text, ":") and
      not String.match?(text, ~r/^[-?:,\[\]{}#&*!|>'"%@`]/) and
      not String.match?(
        text,
        ~r/^(~|null|true|false|yes|no|on|off|y|n|[-+]?(\.?\d.*|\.inf|\.nan))$/i
      )
  end

  # A JSON string or value is valid YAML, quoted and escaped the same way.
  defp scalar(value), do: Jason.encode!(value)

  defp block(text) when is_binary(text) and text != "" do
    chomp = if String.ends_with?(text, "\n"), do: "", else: "-"
    # A first line that starts with a space would be read as the block's indent.
    indent = if String.starts_with?(text, [" ", "\n"]), do: "2", else: ""

    lines =
      text
      |> String.trim_trailing("\n")
      |> String.split("\n")
      |> Enum.map(fn
        "" -> "\n"
        line -> ["  ", line, "\n"]
      end)

    [" |", indent, chomp, "\n", lines]
  end

  defp block(nil), do: " \"\"\n"
  defp block(other), do: [" ", scalar(other), "\n"]

  defp list(items) when is_list(items) and items != [],
    do: ["\n", Enum.map(items, &["  - ", scalar(&1), "\n"])]

  defp list(_none), do: " []\n"
end
