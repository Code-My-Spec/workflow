defmodule WorkflowTest do
  use ExUnit.Case, async: true

  # Two steps: QA writes, the system checks; a failed check goes back to QA.
  defmodule Template do
    @behaviour Workflow.Template

    @impl true
    def steps, do: [%{name: "write", actor: :qa}, %{name: "check", actor: :system}]

    @impl true
    def status(%{name: "write"}, %{written: true}), do: :done
    def status(%{name: "write"}, _facts), do: %{note: "Write it."}
    def status(%{name: "check"}, %{checked: :passed}), do: :done
    def status(%{name: "check"}, %{checked: :failed}), do: {:to, "write", %{note: "It failed."}}
    def status(%{name: "check"}, _facts), do: %{at: "t1"}
  end

  defmodule BadTemplate do
    @behaviour Workflow.Template

    @impl true
    def steps, do: [%{name: "only", actor: :qa}]

    @impl true
    def status(%{name: "only"}, _facts), do: {:to, "missing", %{}}
  end

  defp current(facts), do: Workflow.current(Template, facts)

  test "handing work to an unknown step name raises a helpful error" do
    assert_raise ArgumentError, ~r/missing/, fn ->
      Workflow.current(BadTemplate, %{})
    end
  end

  test "the current step is the first not done, with what it needs" do
    assert current(%{}) == %{name: "write", actor: :qa, note: "Write it."}
    assert current(%{written: true}) == %{name: "check", actor: :system, note: nil, at: "t1"}
    assert %{name: "write", note: "It failed."} = current(%{written: true, checked: :failed})
    assert current(%{written: true, checked: :passed}) == nil
  end

  test "only an agent actor may be woken" do
    assert Workflow.wakes(current(%{})) == :qa
    assert Workflow.wakes(current(%{written: true})) == nil
    assert Workflow.wakes(%{actor: :owner}) == nil
    assert Workflow.wakes(nil) == nil
  end
end
