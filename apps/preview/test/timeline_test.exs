defmodule MedFabric.Preview.TimelineTest do
  use ExUnit.Case, async: true
  alias MedFabric.Preview.Timeline

  test "first emitted packet is zero, dropped source interval advances time only" do
    assert {:ok, plan} = Timeline.plan(Timeline.new(), 4_800, {48_000, 1})
    assert {plan.sequence, plan.tick} == {0, 0}
    timeline = Timeline.submitted(plan)
    assert {:ok, dropped} = Timeline.plan(timeline, 5_760, {48_000, 1})
    assert dropped.sequence == 1
    assert {:ok, later} = Timeline.plan(timeline, 6_720, {48_000, 1})
    assert {later.sequence, later.tick} == {1, 1_920}
    assert Timeline.submitted(later).emitted == 2
  end

  test "backward coordinates and inexact conversion cannot invent media continuity" do
    {:ok, plan} = Timeline.plan(Timeline.new(), 960, {48_000, 1})
    state = Timeline.submitted(plan)
    assert {:error, :source_reset} = Timeline.plan(state, 959, {48_000, 1})
    assert {:error, :source_reset} = Timeline.plan(state, 960, {48_000, 1})
    assert {:error, :inexact_media_tick} = Timeline.plan(state, 961, {44_100, 1})
  end
end
