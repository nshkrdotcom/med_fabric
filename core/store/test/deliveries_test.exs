defmodule MedFabric.Store.DeliveriesTest do
  use ExUnit.Case, async: true
  alias MedFabric.Store.Deliveries, as: D

  defp effect(outcome, protected \\ false),
    do: %{id: outcome, outcome: outcome, protected: protected}

  test "repeat and confirmation are distinct predicates" do
    assert D.dispatch_allowed?([], false)
    assert D.dispatch_allowed?([effect("noncommitted")], false)
    refute D.dispatch_allowed?([effect("matched")], false)
    assert D.confirmation_allowed?([effect("matched")], false)
    refute D.dispatch_allowed?([effect("unknown")], false)
    refute D.confirmation_allowed?([effect("unknown"), effect("matched")], false)
  end

  test "qualification must protect every old delayed effect, not merely the new send" do
    for unsafe <- ["admitted", "possible_send", "unknown", "conflict"] do
      history = [effect(unsafe), effect("matched", true)]
      refute D.dispatch_allowed?(history, true)
      refute D.confirmation_allowed?(history, true)
    end

    protected = [effect("unknown", true), effect("matched", true)]
    assert D.dispatch_allowed?(protected, true)
    assert D.confirmation_allowed?(protected, true)
    refute D.dispatch_allowed?(protected, false)
    refute D.confirmation_allowed?(protected, false)
  end

  test "a search observation does not erase a previous unsafe sender" do
    assert D.confirmation_allowed?([effect("noncommitted"), effect("matched")], false)
    refute D.confirmation_allowed?([effect("possible_send"), effect("matched")], false)
    refute D.dispatch_allowed?([effect("possible_send")], false)
  end
end
