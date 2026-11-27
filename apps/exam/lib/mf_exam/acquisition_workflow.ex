defmodule MedFabric.Exam.AcquisitionWorkflow do
  @moduledoc "Authorized acquisition read models and bounded immutable-index playback."
  alias MedEx.Wire.FrameV1
  alias MedFabric.Exam.{AcquisitionManifest, ClockObservations, PreviewGateway}
  alias MedFabric.Store.AcquisitionSessions, as: S

  def list(context, enc, actor) do
    case S.list(context.db, enc, actor) do
      {:ok, rows} ->
        Enum.map(
          rows,
          &Map.put(&1, :live, if(&1.phase == "capturing", do: latest(&1.id, &1.generation)))
        )

      _ ->
        []
    end
  end

  def publish(bind, spec, raw) do
    with {:ok, frame} <- FrameV1.decode(raw) do
      publish_ecg(bind, spec, frame)
      publish_browser_audio(bind, spec, frame)
    end

    :ok
  end

  defp publish_ecg(bind, spec, frame) do
    if spec.stream_id == "ecg",
      do:
        :ets.insert(
          :mf_live_ecg,
          {:erlang.phash2(bind.id, 64), bind.id, bind.generation,
           System.monotonic_time(:millisecond), spec, frame}
        )
  rescue
    ArgumentError -> :ok
  end

  defp publish_browser_audio(bind, spec, frame) do
    if spec.stream_id == "audio" and bind.source_kind == :browser do
      monitor = %{frame | stream_number: 3}

      case FrameV1.encode(monitor) do
        {:ok, derived} -> PreviewGateway.feed(bind, spec, derived)
        _ -> :ok
      end
    end
  end

  defp latest(id, generation) do
    case :ets.lookup(:mf_live_ecg, :erlang.phash2(id, 64)) do
      [{_, ^id, ^generation, at, spec, frame}] ->
        if System.monotonic_time(:millisecond) - at <= 1500,
          do: trace(spec, frame.first_sample, frame.payload)

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  def stop(context, enc, id, actor), do: S.stop(context.db, enc, id, actor)

  def segment(context, enc, id, actor, digest, name, first, sha) when name in ["audio", "ecg"] do
    with {:ok, manifest} <- AcquisitionManifest.promoted(context, enc, id, actor, digest),
         %{"index" => index, "digest" => index_digest} <- manifest["streams"][name],
         [row] <-
           Enum.filter(index["segments"], &(&1["first_sample"] == first and &1["sha256"] == sha)),
         {:ok, spec} <- MedEx.Serialization.stream_spec(index["stream"]),
         {:ok, segment} <- MedEx.Serialization.segment_ref(row),
         expected = %{
           root_owner: context.root_owner,
           manifest_digest: digest,
           index_digest: index_digest,
           descriptor_ref: spec.descriptor_ref,
           fence: index["fence"],
           journal_id: index["journal_id"],
           stream_id: name,
           source_epoch: spec.source_epoch
         },
         {:ok, verified} <-
           MedEx.Storage.File.read_verified_index(
             AcquisitionManifest.attempt_dir(context, id, name, index["fence"]),
             index_digest,
             expected
           ),
         {:ok, raw} <-
           MedEx.Storage.File.read_verified_segment(verified, segment.first_sample, expected) do
      {:ok, spec, segment, raw}
    else
      _ -> {:error, :unverified_segment}
    end
  end

  def segment(_, _, _, _, _, _, _, _), do: {:error, :unknown_stream}

  def trace(spec, first, raw) do
    bits = MedEx.StreamSpec.bytes_per_value(spec.encoding) * 8
    channels = length(spec.channels)
    channel = hd(spec.channels)
    rows = max(1, div(byte_size(raw) * 8, bits * channels))
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
end
