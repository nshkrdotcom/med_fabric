Code.require_file("soak.exs", __DIR__)
ExUnit.start()

defmodule MedFabric.Acceptance.SoakTest do
  use ExUnit.Case, async: true
  alias MedFabric.Acceptance.Soak

  test "a signal must exceed the lag budget twice in a row after warmup" do
    bad = %{capture_lag_ms: 2_001, durable_lag_ms: 3_000, interruption: nil}
    recovered = %{bad | capture_lag_ms: 2_000}
    point = %{capture_ms: 9_999, elapsed_ms: 10_000, streams: %{"audio" => bad}}

    assert {%{}, []} = Soak.assess(point, %{})
    point = %{point | capture_ms: 10_000}
    assert {streaks, []} = Soak.assess(point, %{})
    point = %{point | capture_ms: 15_000, streams: %{"audio" => recovered}}

    assert {streaks, [%{stream: "audio", signal: :durable_lag_ms, observed_ms: 3_000}]} =
             Soak.assess(point, streaks)

    assert streaks == %{{"audio", :durable_lag_ms} => 2}
  end

  test "startup and source interruption produce distinct failures" do
    point = %{capture_ms: nil, elapsed_ms: 15_000, streams: %{}}
    assert {%{}, [%{signal: :capture_did_not_start}]} = Soak.assess(point, %{})

    point = %{point | capture_ms: 1_000, streams: %{"ecg" => %{interruption: "spool_full"}}}

    assert {%{}, [%{stream: "ecg", signal: :source_interrupted, reason: "spool_full"}]} =
             Soak.assess(point, %{})
  end
end
