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
      {:ok, yml} -> {:ok, yml |> String.split("\n") |> read_fields(%{}) |> own_id()}
      {:error, _none} -> {:none, path}
    end
  end

  # A file in the story's shape (no `kind:`) holds the story's own id as `id:`;
  # the work's id stays its file name, so the story's is kept as `story_id`.
  defp own_id(%{"kind" => _kind} = fields), do: fields

  defp own_id(fields) do
    case Map.pop(fields, "id") do
      {nil, fields} -> fields
      {id, fields} -> Map.put(fields, "story_id", id)
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
        # A rule starts with its `rule:` or its `id:`; the other follows under it.
        match = Regex.run(~r/^  - (rule|id): (.*)$/, line) ->
          [_, key, value] = match
          [%{"scenarios" => [], key => read_scalar(value)} | rules]

        (match = Regex.run(~r/^    (rule|id): (.*)$/, line)) && rules != [] ->
          [_, key, value] = match
          [rule | others] = rules
          [Map.put(rule, key, read_scalar(value)) | others]

        (match = Regex.run(~r/^      - (.*)$/, line)) && rules != [] ->
          [rule | others] = rules
          scenario = read_scenario(Enum.at(match, 1))
          [Map.update!(rule, "scenarios", &(&1 ++ [scenario])) | others]

        # A scenario's other key (its id, or its happy or fails under its id).
        (match = Regex.run(~r/^        ([A-Za-z_]+): (.*)$/, line)) && rules != [] ->
          [_, key, value] = match
          [rule | others] = rules

          scenarios =
            List.update_at(rule["scenarios"], -1, fn
              %{} = scenario -> Map.put(scenario, key, read_scalar(value))
              other -> other
            end)

          [Map.put(rule, "scenarios", scenarios) | others]

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

  @doc """
  A story's criteria as `criteria/1` gives them, each followed by the ids of its
  rule and scenario where the story has them, as `(rule <id>, scenario <id>)`.
  """
  @spec labelled(map()) :: list() | nil
  def labelled(%{"rules" => rules} = work) when is_list(rules) do
    criteria = criteria(work)

    named =
      for rule <- rules,
          scenario <- List.wrap(get(rule, "scenarios")),
          do: [{"rule", get(rule, "id")}, {"scenario", get(scenario, "id")}]

    if is_list(criteria) and length(criteria) == length(named) do
      Enum.zip_with(criteria, named, fn criterion, ids ->
        case for({what, "" <> id} <- ids, id != "", do: "#{what} #{id}") do
          [] -> criterion
          said -> "#{criterion} (#{Enum.join(said, ", ")})"
        end
      end)
    else
      criteria
    end
  end

  def labelled(work), do: criteria(work)

  @alphabet ~c"23456789abcdefghjkmnpqrstuvwxyz"

  @doc "A new id: 8 random characters from #{@alphabet}, none of those `taken`."
  @spec new_id(Enumerable.t()) :: String.t()
  def new_id(taken \\ []) do
    id = for _ <- 1..8, into: "", do: <<Enum.random(@alphabet)>>
    if id in taken, do: new_id(taken), else: id
  end

  @doc """
  The story with an id generated for itself (`story_id`), each rule and each
  scenario that has none, unique within the story; the ids it was given are kept.
  """
  @spec with_ids(map()) :: map()
  def with_ids(story) do
    {story_id, taken} = given_or_new(story["story_id"], MapSet.new(ids(story)))
    story = Map.put(story, "story_id", story_id)

    case story["rules"] do
      rules when is_list(rules) ->
        {rules, _taken} = Enum.map_reduce(rules, taken, &rule_with_ids/2)
        Map.put(story, "rules", rules)

      _none ->
        story
    end
  end

  defp rule_with_ids(%{} = rule, taken) do
    {id, taken} = given_or_new(rule["id"], taken)

    {scenarios, taken} =
      Enum.map_reduce(List.wrap(rule["scenarios"]), taken, fn
        %{} = scenario, taken ->
          {id, taken} = given_or_new(scenario["id"], taken)
          {Map.put(scenario, "id", id), taken}

        other, taken ->
          {other, taken}
      end)

    {rule |> Map.put("id", id) |> Map.put("scenarios", scenarios), taken}
  end

  defp rule_with_ids(other, taken), do: {other, taken}

  defp given_or_new("" <> id, taken) when id != "", do: {id, taken}

  defp given_or_new(_none, taken) do
    id = new_id(taken)
    {id, MapSet.put(taken, id)}
  end

  # Every id the story holds, in order: its own, then each rule's and its scenarios'.
  defp ids(story) do
    rules = List.wrap(story["rules"])

    [story["story_id"]]
    |> Enum.concat(
      Enum.flat_map(rules, fn rule ->
        [get(rule, "id") | Enum.map(List.wrap(get(rule, "scenarios")), &get(&1, "id"))]
      end)
    )
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  @doc """
  Why a story in the story's shape cannot be handed in for its ids: the refusal
  naming each part (the story, a rule or a scenario, by position and text) with
  no id and each id that repeats; nil when every part has an id of its own.
  """
  @spec ids_refused(map()) :: String.t() | nil
  def ids_refused(story) do
    rules = List.wrap(story["rules"])

    in_rules =
      for {rule, r} <- Enum.with_index(rules, 1) do
        scenarios =
          for {scenario, s} <- Enum.with_index(List.wrap(get(rule, "scenarios")), 1),
              blank?(get(scenario, "id")),
              do: "scenario #{s} of rule #{r} (#{inspect(scenario_text(scenario))})"

        [blank?(get(rule, "id")) && "rule #{r} (#{inspect(get(rule, "rule"))})", scenarios]
      end

    missing =
      [blank?(story["story_id"]) && "the story", in_rules]
      |> List.flatten()
      |> Enum.filter(&is_binary/1)

    repeated =
      for {id, n} <- Enum.frequencies(ids(story)), n > 1, do: "#{id} (#{n} times)"

    said =
      Enum.reject(
        [
          missing != [] && "these have no id: #{Enum.join(missing, "; ")}",
          repeated != [] && "these ids repeat: #{Enum.join(Enum.sort(repeated), ", ")}"
        ],
        &(&1 == false)
      )

    if said != [] do
      "Refused: story #{story["id"]} cannot be handed in, #{Enum.join(said, "; and ")}. " <>
        "The story, each rule and each scenario needs an id of its own (`id:`), 8 " <>
        "characters from #{@alphabet}. Nothing was started."
    end
  end

  defp blank?(id), do: not is_binary(id) or id == ""

  defp get(%{} = map, key), do: map[key]
  defp get(_other, _key), do: nil

  defp scenario_text(scenario) when is_map(scenario) do
    scenario |> Map.delete("id") |> Map.values() |> Enum.map(&to_string/1) |> Enum.join(" ")
  end

  defp scenario_text(scenario), do: to_string(scenario)

  @doc "The work as YAML: in the story's shape when handed in with it, else its id, kind, text and criteria (a journey's stages)."
  @spec yaml(map()) :: String.t()
  def yaml(%{"kind" => "story"} = work)
      when is_map_key(work, "rules") or is_map_key(work, "story") or is_map_key(work, "title") do
    IO.iodata_to_binary([
      id_line("", work["story_id"]),
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
          id_line("    ", rule["id"]),
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

  defp scenario(%{"id" => id} = scenario) do
    case Enum.to_list(Map.delete(scenario, "id")) do
      [{kind, text} | more] ->
        [
          ["      - ", plain(kind), ": ", plain(text), "\n"],
          Enum.map(more, fn {kind, text} -> ["        ", plain(kind), ": ", plain(text), "\n"] end),
          id_line("        ", id)
        ]

      [] ->
        ["      - id: ", plain(id), "\n"]
    end
  end

  defp scenario(scenario) when is_map(scenario) do
    Enum.map(scenario, fn {kind, text} -> ["      - ", plain(kind), ": ", plain(text), "\n"] end)
  end

  defp scenario(text), do: ["      - ", plain(text), "\n"]

  # A story's, rule's or scenario's `id:` line, where it has one.
  defp id_line(indent, "" <> id) when id != "", do: [indent, "id: ", plain(id), "\n"]
  defp id_line(_indent, _none), do: []

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
