defmodule MedFabric.Exam.DeviceWorkflow do
  @moduledoc "Read models for the authenticated encounter's clinical device review."
  alias MedFabric.Exam.{ClockObservations, DeviceManifest}
  alias MedFabric.Store.{DeviceSessions, Postgres}

  alias DeviceSessions, as: S

  def list(enc) do
    for [id, profile, device, site, phase, m, digest, choice, descriptors] <-
          S.rows(
            Postgres,
            """
            SELECT s.id,s.profile,s.device_id,s.site,s.phase,m.body,m.digest,r.choice,s.descriptors FROM device_sessions s
            LEFT JOIN device_manifests m ON m.acquisition_id=s.id LEFT JOIN device_reviews r ON r.acquisition_id=s.id
            WHERE s.encounter_id=$1 ORDER BY s.created_at DESC LIMIT 32
            """,
            [enc]
          ) do
      metrics =
        S.rows(
          Postgres,
          "SELECT a.id,a.evidence->>'kind',d.remote_ref FROM acquisitions a JOIN outbox_deliveries d ON d.acquisition_id=a.id AND d.encounter_id=a.encounter_id WHERE a.encounter_id=$1 AND a.parent_acquisition_id=$2",
          [enc, id]
        )

      facts =
        S.rows(
          Postgres,
          "SELECT kind,fact FROM device_facts WHERE acquisition_id=$1 AND kind IN ('status','command_applied','command_outcome_unknown','command_reconciled','operator_stop') ORDER BY ordinal DESC LIMIT 8",
          [id]
        )

      %{
        id: id,
        profile: profile,
        device: device,
        site: site,
        phase: phase,
        manifest: m,
        digest: digest,
        choice: choice,
        metrics: metrics,
        facts: facts,
        descriptors: descriptors,
        live: latest(id)
      }
    end
  end

  defp latest(id) do
    with table when table != :undefined <- :ets.whereis(:mf_live_ecg),
         [{_, at, spec, frame}] <- :ets.lookup(table, id),
         true <- System.monotonic_time(:millisecond) - at <= 1500 do
      trace(spec, frame.first_sample, frame.payload)
    else
      _ -> nil
    end
  end

  def trace(spec, first, raw) do
    bits = MedEx.StreamSpec.bytes_per_value(spec.encoding) * 8
    channels = length(spec.channels)
    channel = hd(spec.channels)
    rows = div(byte_size(raw) * 8, bits * channels)
    step = max(1, div(rows, 800))

    points =
      for i <- 0..(rows - 1)//step do
        <<v::little-signed-size(^bits)>> =
          binary_part(raw, div(i * channels * bits, 8), div(bits, 8))

        case channel.calibration do
          :unknown -> {i, v}
          %{zero: z, scale_num: n, scale_den: d} -> {i, (v - z) * n / d}
        end
      end

    {low, high} = points |> Enum.map(&elem(&1, 1)) |> Enum.min_max()

    plotted =
      Enum.map_join(points, " ", fn {i, v} ->
        y = if high == low, do: 62.5, else: 120 - (v - low) * 115 / (high - low)
        "#{i * 800 / max(1, rows - 1)},#{y}"
      end)

    %{
      points: plotted,
      unit: if(channel.calibration == :unknown, do: "raw counts", else: channel.unit),
      low: low,
      high: high,
      first: first,
      end_sample: first + rows,
      step: step,
      label: channel.label
    }
  end

  def segment(enc, id, digest, name, sha), do: segment(enc, id, digest, name, nil, sha)

  def segment(enc, id, digest, name, first, sha) when name in ["audio", "ecg"] do
    with [[^digest, m]] <-
           S.rows(
             Postgres,
             "SELECT m.digest,m.body FROM device_manifests m JOIN device_sessions s ON m.acquisition_id=s.id WHERE s.encounter_id=$1 AND s.id=$2",
             [enc, id]
           ),
         %{"index" => ix} <- m["streams"][name],
         [row] <- Enum.filter(ix["segments"], &segment_matches?(&1, first, sha)),
         {:ok, spec} <- MedEx.Serialization.stream_spec(ix["stream"]),
         {:ok, segment} <- MedEx.Serialization.segment_ref(row),
         {:ok, raw} <-
           MedEx.Storage.File.read_segment(
             DeviceManifest.attempt_dir(id, name, ix["fence"]),
             segment
           ) do
      {:ok, spec, segment, raw}
    else
      _ -> {:error, :unverified_segment}
    end
  end

  def segment(_, _, _, _, _, _), do: {:error, :unknown_stream}

  defp segment_matches?(row, first, sha),
    do: row["sha256"] == sha and (is_nil(first) or row["first_sample"] == first)

  def band(m, index) do
    a = m["streams"]["audio"]
    e = m["streams"]["ecg"]

    with true <-
           Enum.any?(
             a["index"]["segments"],
             &(n(&1["first_sample"]) <= index and index < n(&1["end_sample"]))
           ),
         {:ok, {lo, hi}} <- ClockObservations.interval(a["clock"], index) do
      Enum.flat_map(e["index"]["segments"], &overlap(&1, e["clock"], lo, hi))
    else
      _ -> :unavailable
    end
  catch
    :unavailable -> :unavailable
  end

  defp overlap(segment, clock, low, high) do
    first = n(segment["first_sample"])
    last = n(segment["end_sample"])
    left = lower(first, last, fn index -> elem(clock_interval!(clock, index), 1) >= low end)
    right = lower(left, last, fn index -> elem(clock_interval!(clock, index), 0) > high end)
    if left < right, do: [{left, right}], else: []
  end

  defp clock_interval!(clock, index) do
    case ClockObservations.interval(clock, index) do
      {:ok, interval} -> interval
      _ -> throw(:unavailable)
    end
  end

  defp lower(a, a, _), do: a

  defp lower(a, b, p) do
    k = div(a + b, 2)
    if p.(k), do: lower(a, k, p), else: lower(k + 1, b, p)
  end

  defp n(v), do: String.to_integer(v)

  def stop(enc, id, actor) do
    case S.rows(
           Postgres,
           "INSERT INTO device_facts(acquisition_id,kind,fact) SELECT s.id,'operator_stop',jsonb_build_object('actor',$3::text) FROM device_sessions s JOIN encounters e ON e.id=s.encounter_id WHERE s.id=$1 AND e.id=$2 AND e.clinician_actor=$3 AND e.closed_at IS NULL AND s.phase='capturing' FOR SHARE OF s,e RETURNING ordinal",
           [id, enc, actor]
         ) do
      [[_]] -> :ok
      _ -> {:error, :denied}
    end
  end
end
