defmodule MedFabric.Exam.DeviceReviews do
  @moduledoc "One digest-bound clinical decision and atomic derived evidence/outbox creation."
  alias MedFabric.Domain.DeviceMeasurement
  alias MedFabric.Exam.DeviceManifest
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.DeviceSessions, as: S
  alias MedFabric.Store.{Postgres, Records}

  def review_verified(enc, id, actor, digest, choice) do
    with :ok <- DeviceManifest.verify_review(enc, id, actor, digest),
         do: review(enc, id, actor, digest, choice)
  end

  defp review(enc, id, actor, digest, choice) do
    Postgrex.transaction(Postgres, fn tx ->
      case S.rows(
             tx,
             """
             SELECT m.digest,m.body,s.device_id,e.destination,e.patient_ref,e.encounter_ref
             FROM device_manifests m JOIN device_sessions s ON m.acquisition_id=s.id
             JOIN encounters c ON c.id=s.encounter_id JOIN encounter_exports e ON e.encounter_id=c.id
             WHERE s.id=$1 AND c.id=$2 AND c.clinician_actor=$3 AND c.closed_at IS NULL FOR UPDATE OF s,c
             """,
             [id, enc, actor]
           ) do
        [[^digest, manifest, device, destination, patient, encounter]] ->
          source = %{
            encounter_id: enc,
            device: device,
            destination: destination,
            refs: %{"patient_ref" => patient, "encounter_ref" => encounter}
          }

          review_locked(tx, [id, digest, actor, choice], manifest, source)

        _ ->
          S.abort(tx, :review_changed)
      end
    end)
  end

  defp review_locked(tx, [id, digest, actor, choice] = params, manifest, source) do
    case S.rows(tx, "SELECT digest,actor,choice FROM device_reviews WHERE acquisition_id=$1", [id]) do
      [[^digest, ^actor, ^choice]] ->
        :ok

      [] ->
        validate!(tx, manifest, choice)

        [[at]] =
          S.rows(
            tx,
            "INSERT INTO device_reviews(acquisition_id,digest,actor,choice) VALUES($1,$2,$3,$4) RETURNING reviewed_at",
            params
          )

        Enum.each(choice["metrics"] || [], fn code ->
          event = Enum.find_value(manifest["inventory"], &matching_event(&1, choice["event_id"]))
          insert_metric(tx, id, actor, source, event, code, at)
        end)

        :ok

      _ ->
        S.abort(tx, :review_conflict)
    end
  end

  defp matching_event(row, id) do
    if row["event"]["event_id"] == id, do: row["event"]
  end

  defp insert_metric(tx, id, actor, source, event, code, at) do
    with {:ok, evidence} <-
           DeviceMeasurement.derived(event, code, id, source.device, DateTime.to_iso8601(at)),
         metric_id =
           S.hash(
             "medfabric.metric.v1" <>
               <<0>> <> MedEx.CanonicalJSON.encode([id, event["event_id"], code])
           ),
         external = source.encounter_id <> ":" <> metric_id,
         {:ok, resource} <- FhirClient.resource_checked(evidence, external, actor, source.refs) do
      S.rows(
        tx,
        "INSERT INTO acquisitions(encounter_id,id,evidence,capture_profile,parent_acquisition_id,source_event_id) VALUES($1,$2,$3,'derived_device_metric',$4,$5)",
        [source.encounter_id, metric_id, evidence, id, event["event_id"]]
      )

      Records.insert_acceptance(tx, [source.encounter_id, metric_id, actor], [
        source.destination,
        external,
        resource
      ])
    else
      _ -> S.abort(tx, :ineligible_metric)
    end
  end

  defp validate!(tx, manifest, choice) do
    metrics = choice["metrics"] || []
    note = choice["note"]

    unless is_list(metrics) and is_binary(note) and byte_size(note) <= 2000 and
             valid_decision?(choice["decision"], manifest, choice, metrics) do
      S.abort(tx, :invalid_review)
    end
  end

  defp valid_decision?(decision, _, _, metrics) when decision in ["reject", "repeat"],
    do: metrics == []

  defp valid_decision?("complete", manifest, choice, metrics) do
    manifest["profile"] == "paired_exam" and manifest["defects"] == [] and metrics == [] and
      ranges?(manifest, choice)
  end

  defp valid_decision?("partial", manifest, choice, metrics) do
    manifest["profile"] == "paired_exam" and metrics == [] and ranges?(manifest, choice) and
      manifest["defects"] != [] and choice["acknowledged"] == manifest["defects"] and
      choice["note"] != ""
  end

  defp valid_decision?("accept_metrics", manifest, choice, metrics) do
    manifest["profile"] == "plx_spot_check" and
      Enum.sort(metrics) in [["pulse_rate"], ["spo2"], ["pulse_rate", "spo2"]] and
      Enum.any?(manifest["inventory"], &(&1["event"]["event_id"] == choice["event_id"]))
  end

  defp valid_decision?(_, _, _, _), do: false

  defp ranges?(manifest, %{"ranges" => ranges}) when is_list(ranges) and length(ranges) in 1..256,
    do: Enum.all?(ranges, &range?(manifest, &1))

  defp ranges?(_, _), do: false

  defp range?(manifest, %{"stream" => stream, "first" => first, "end" => last})
       when is_binary(first) and is_binary(last) do
    with {:ok, a} <- sample_number(first),
         {:ok, b} <- sample_number(last),
         true <- a < b do
      segments = get_in(manifest, ["streams", stream, "index", "segments"]) || []

      segments
      |> Enum.drop_while(&(String.to_integer(&1["end_sample"]) <= a))
      |> covers?(a, b)
    else
      _ -> false
    end
  end

  defp range?(_, _), do: false

  defp covers?([first | rest], a, b) do
    start = String.to_integer(first["first_sample"])
    ending = String.to_integer(first["end_sample"])
    start <= a and a < ending and covers_next?(rest, ending, b, first["config_epoch"])
  end

  defp covers?([], _, _), do: false

  defp covers_next?(_, ending, target, _) when ending >= target, do: true

  defp covers_next?([segment | rest], ending, target, epoch) do
    segment["config_epoch"] == epoch and String.to_integer(segment["first_sample"]) == ending and
      covers_next?(rest, String.to_integer(segment["end_sample"]), target, epoch)
  end

  defp covers_next?([], _, _, _), do: false

  defp sample_number(value) do
    if byte_size(value) <= 20 and Regex.match?(~r/\A(0|[1-9][0-9]*)\z/, value) do
      sample = String.to_integer(value)
      if sample <= 0xFFFFFFFFFFFFFFFF, do: {:ok, sample}, else: :error
    else
      :error
    end
  end
end
