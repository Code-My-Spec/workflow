defmodule Workflow.IdsArePlainNamesTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  @moduletag :tmp_dir

  defp say(to) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "say", "arguments" => %{"say" => "hello", "to" => to}}
    }

    conn(:post, "/mcp", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Workflow.Router.call(Workflow.Router.init([]))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
    |> get_in(["result", "content", Access.at(0), "text"])
  end

  test "an id or inbox name that is not a plain name is refused at its door, and nothing is made from it",
       %{tmp_dir: dir} do
    bad = "../ids-are-plain-names-x"
    outside = Workflow.Messages.inbox(bad)
    plain = Workflow.Messages.inbox("ids-are-plain-names-ok")
    on_exit(fn -> Enum.each([outside, plain, plain <> ".read"], &File.rm/1) end)

    # The inbox door: the bad name is refused, naming it, and no inbox file is written.
    assert say(bad) =~ ~s(Refused: "#{bad}" is not a plain name)
    refute File.exists?(outside)

    # A plain name is kept as today.
    assert say("ids-are-plain-names-ok") =~ "Kept in ids-are-plain-names-ok's inbox"
    assert File.exists?(plain)

    # A manager tool's door: refused, naming the id, before anything is looked at.
    tell = Enum.find(Workflow.Manager.tools(%{"repo" => dir}), &(&1.name == "tell"))
    assert {:ok, ~s(Refused: "../x") <> _} = tell.execute.(%{"id" => "../x", "say" => "hi"}, %{})

    assert {:ok, "There is no work a-b running."} =
             tell.execute.(%{"id" => "a-b", "say" => "hi"}, %{})
  end
end
