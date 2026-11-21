defmodule Workflow.KnowledgeTest do
  use ExUnit.Case, async: true

  alias Workflow.Knowledge

  test "ship-knowledge: criterion 1 the package carries the framework knowledge under its own priv dir" do
    assert Knowledge.dir() == Application.app_dir(:workflow, "priv/knowledge")

    list = Knowledge.list()

    assert list == Enum.sort(list)
    assert "ponytail.md" in list
    # The coder's knowledge moved beside the coder skill's SKILL.md.
    refute "conventions.md" in list
  end

  test "each role's knowledge lives beside its skill, so only ponytail.md is left here" do
    assert Knowledge.list() == ["ponytail.md"]
  end
end
