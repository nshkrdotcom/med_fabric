defmodule MedFabric.Handheld.Spool.Plan do
  @moduledoc false
  alias MedEx.{IntegritySpan, SampleFrame, Serialization, StreamCursor, StreamSpec}
  alias MedEx.Wire.{Control, FrameV1}

  def record(<<"MEX1", _::binary>> = raw, %StreamSpec{} = spec) do
    number = if spec.stream_id == "audio", do: 1, else: 2

    case FrameV1.decode(raw) do
      {:ok, %FrameV1{stream_number: ^number} = frame} ->
        value =
          struct!(
            SampleFrame,
            Map.take(
              Map.from_struct(frame),
              ~w(source_epoch config_epoch sequence first_sample sample_count payload)a
            )
            |> Map.merge(%{stream_id: spec.stream_id, descriptor_ref: spec.descriptor_ref})
          )

        with :ok <- SampleFrame.validate(value, spec) do
          {:ok,
           %{
             key: {frame.sequence, frame.first_sample},
             event: {:frame, value},
             id: "frame-#{frame.sequence}-#{frame.first_sample}",
             fingerprint: Serialization.sha256(raw),
             bytes: byte_size(raw)
           }}
        end

      _ ->
        {:error, :invalid_source_frame}
    end
  end

  def record(raw, %StreamSpec{} = spec) when is_binary(raw) and byte_size(raw) <= 16_384 do
    with {:ok, gap} when is_map(gap) <- MedEx.CanonicalJSON.decode(raw),
         true <-
           Enum.sort(Map.keys(gap)) ==
             Enum.sort(~w(id irreversible cause first end first_sequence next_sequence)),
         true <-
           gap["irreversible"] == true and MedEx.ContractRules.id?(gap["id"]) and
             byte_size(gap["id"]) <= 92 and
             MedEx.ContractRules.id?(gap["cause"]),
         {:ok, first} <- Control.uint64(gap["first"]),
         {:ok, ending} <- Control.uint64(gap["end"]),
         {:ok, q} <- Control.uint64(gap["first_sequence"]),
         {:ok, next} <- Control.uint64(gap["next_sequence"]) do
      span = %IntegritySpan{
        stream_id: spec.stream_id,
        source_epoch: spec.source_epoch,
        code: :source_gap,
        source: spec.source_ref,
        first_sample: first,
        end_sample: ending,
        context: %{"cause" => gap["cause"]}
      }

      value = %{
        id: gap["id"],
        span: span,
        first_sequence: q,
        next_sequence: next,
        irreversible: true
      }

      with :ok <- IntegritySpan.validate(span), true <- next >= q do
        {:ok,
         %{
           key: {q, first},
           event: {:gap, value},
           id: "gap-" <> gap["id"],
           fingerprint: Serialization.sha256(MedEx.CanonicalJSON.encode(gap)),
           bytes: byte_size(raw),
           gap: gap
         }}
      else
        _ -> {:error, :invalid_source_gap}
      end
    else
      _ -> {:error, :invalid_source_gap}
    end
  end

  def record(_, _), do: {:error, :invalid_source_record}

  def advance(%StreamCursor{} = cursor, metadata) do
    case StreamCursor.plan(cursor, metadata.event) do
      {:ok, next, _effects} -> {:ok, next}
      {:error, _} = error -> error
      _ -> {:error, :source_discontinuity}
    end
  end

  def coverage(records, %StreamCursor{} = start, {sequence, sample} = target) do
    if start.next_sequence > sequence or start.next_sample > sample do
      {:error, :uncovered_receipt}
    else
      walk(records, start, target, [], map_size(records) + 1)
    end
  end

  defp walk(_, %{next_sequence: q, next_sample: sample}, {q, sample}, visited, _),
    do: {:ok, Enum.reverse(visited)}

  defp walk(records, cursor, {q, sample} = target, visited, budget) when budget > 0 do
    key = {cursor.next_sequence, cursor.next_sample}

    with {:ok, metadata} <- Map.fetch(records, key),
         {:ok, next} <- advance(cursor, metadata),
         true <- next.next_sequence <= q and next.next_sample <= sample,
         true <- {next.next_sequence, next.next_sample} != key do
      walk(records, next, target, [key | visited], budget - 1)
    else
      _ -> {:error, :uncovered_receipt}
    end
  end

  defp walk(_, _, _, _, _), do: {:error, :uncovered_receipt}

  def tail(records, cursor), do: tail(records, cursor, map_size(records) + 1)

  defp tail(records, cursor, budget) when budget > 0 do
    case Map.fetch(records, {cursor.next_sequence, cursor.next_sample}) do
      :error ->
        {:ok, cursor}

      {:ok, metadata} ->
        with {:ok, next} <- advance(cursor, metadata), do: tail(records, next, budget - 1)
    end
  end

  defp tail(_, _, _), do: {:error, :source_discontinuity}
end
