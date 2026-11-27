defmodule MedFabric.Preview.Timeline do
  @moduledoc "Per-peer emitted sequence and exact elapsed media ticks; RTP wrapping belongs to RTC."
  def new, do: %{origin: nil, last: nil, emitted: 0}

  def plan(state, sample, {num, den})
      when is_integer(sample) and sample >= 0 and is_integer(num) and num > 0 and
             is_integer(den) and den > 0 do
    origin = state.origin || sample
    ticks = (sample - origin) * 48_000 * den

    cond do
      state.last != nil and sample <= state.last ->
        {:error, :source_reset}

      ticks < 0 ->
        {:error, :source_reset}

      rem(ticks, num) != 0 ->
        {:error, :inexact_media_tick}

      div(ticks, num) > 0xFFFFFFFFFFFFFFFF ->
        {:error, :media_time_limit}

      true ->
        {:ok, %{sequence: state.emitted, tick: div(ticks, num), sample: sample, origin: origin}}
    end
  end

  def plan(_, _, _), do: {:error, :invalid_media_time}
  def submitted(plan), do: %{origin: plan.origin, last: plan.sample, emitted: plan.sequence + 1}
end
