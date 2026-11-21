defmodule Workflow.ServerTest do
  use ExUnit.Case, async: false

  setup do
    was = Application.get_env(:workflow, :manager)
    on_exit(fn -> Application.put_env(:workflow, :manager, was) end)
  end

  test "a say is answered with the manager's reply under the same ref, or says why not" do
    Application.put_env(:workflow, :manager, %{"agent" => %{"provider" => "claude-code"}})
    say = %{"ref" => "r1", "text" => "hello"}

    assert {"said", %{"ref" => "r1", "text" => "hi back"}} =
             Workflow.Server.answer(say, fn "hello" -> "hi back" end)

    assert {"said", %{"ref" => "r1", "text" => "The manager failed" <> _}} =
             Workflow.Server.answer(say, fn _ -> raise "boom" end)

    Application.delete_env(:workflow, :manager)

    assert {"said", %{"ref" => "r1", "text" => "The loop has no manager" <> _}} =
             Workflow.Server.answer(say, fn _ -> flunk("not asked") end)
  end
end
