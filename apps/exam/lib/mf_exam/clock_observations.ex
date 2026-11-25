defmodule MedFabric.Exam.ClockObservations do
  @moduledoc "Qualified synthetic acquisition anchors and transport probes pinned at review."
  alias MedEx.{ClockAlign, Serialization}

  @key {__MODULE__, :generation}

  def host_generation, do: :persistent_term.get(@key)

  def initialize_host_generation do
    case :persistent_term.get(@key, nil) do
      nil ->
        gen = Base.encode16(:crypto.strong_rand_bytes(12))
        :persistent_term.put(@key, gen)
        gen

      gen ->
        gen
    end
  end

  def wall_mapping do
    before_us = System.system_time(:microsecond)
    mono = System.monotonic_time(:microsecond)
    after_us = System.system_time(:microsecond)

    %{
      "host_monotonic_us" => to_string(mono),
      "wall_before_us" => to_string(before_us),
      "wall_after_us" => to_string(after_us),
      "host_generation" => host_generation(),
      "method" => "same_host_lab_bracket"
    }
  end

  def now, do: System.monotonic_time(:microsecond)

  def freeze(name, spec, facts) do
    with %{"body" => a} <-
           Enum.find(facts, &(&1["type"] == "anchor" and &1["body"]["stream"] == name)),
         "fixture_acquisition_tick" <- a["method"],
         probes when probes != [] <-
           for(
             %{"type" => "probe", "body" => p} <- facts,
             p["stream"] == name and p["host_generation"] == host_generation(),
             do: p
           ),
         %{domain_id: _, tick_rate: {tick, den}} <- spec.clock,
         true <- tick > 0 do
      gen = {host_generation(), spec.boot_id}

      ps =
        Enum.map(probes, fn p ->
          %{generation: gen, h1: n(p["h1"]), h4: n(p["h4"]), d2: n(p["d2"]), d3: n(p["d3"])}
        end)

      {rn, rd} = spec.sample_rate

      anchor = %{
        generation: gen,
        sample_index: n(a["sample_index"]),
        device_us: {n(a["tick"]) * 1_000_000 * den, tick},
        period_min_us: {1_000_000 * rd, rn},
        period_max_us: {1_000_000 * rd, rn},
        error_us: n(a["error_us"])
      }

      policy = %{
        generation: gen,
        a_min: {999_900, 1_000_000},
        a_max: {1_000_100, 1_000_000},
        epsilon_us: 2,
        host_now_us: now(),
        max_probe_age_us: 1_800_000_000,
        valid_device_us: {0, 3_600_000_000},
        holdover_rate: {1, 10_000}
      }

      case ClockAlign.fit(ps, policy) do
        {:ok, est} ->
          %{
            "state" => "bounded",
            "estimate" => Serialization.to_map(est),
            "wall_mapping" => wall_mapping(),
            "anchor" => Serialization.to_map(anchor),
            "qualification" => "synthetic reference peripheral only"
          }

        {:unavailable, r} ->
          unavailable(r)
      end
    else
      _ -> unavailable(:missing_qualified_observations)
    end
  end

  def interval(%{"state" => "bounded", "estimate" => e, "anchor" => a}, index) do
    generation = List.to_tuple(e["generation"])

    estimate = %{
      generation: generation,
      valid_device_us: pair(e["valid_device_us"]),
      probe_span_us: pair(e["probe_span_us"]),
      holdover_rate: q(e["holdover_rate"]),
      vertices: Enum.map(e["vertices"], fn [x, y] -> {q(x), q(y)} end)
    }

    anchor = %{
      generation: generation,
      sample_index: n(a["sample_index"]),
      device_us: q(a["device_us"]),
      period_min_us: q(a["period_min_us"]),
      period_max_us: q(a["period_max_us"]),
      error_us: q(a["error_us"])
    }

    ClockAlign.interval(estimate, anchor, index)
  end

  def interval(_, _), do: {:unavailable, :clock_unavailable}
  defp pair([a, b]), do: {n(a), n(b)}
  defp q([a, b]), do: {n(a), n(b)}
  defp q(s), do: n(s)
  defp n(s), do: String.to_integer(s)
  defp unavailable(reason), do: %{"state" => "unavailable", "reason" => to_string(reason)}
end
