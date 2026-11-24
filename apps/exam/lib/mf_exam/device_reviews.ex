defmodule MedFabric.Exam.DeviceReviews do
  @moduledoc "One digest-bound clinical decision and atomic derived evidence/outbox creation."
  alias MedFabric.Domain.DeviceMeasurement
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.{DeviceSessions,Postgres,Records}
  alias DeviceSessions, as: S

  def review_verified(enc,id,actor,digest,choice) do
    with :ok <- MedFabric.Exam.DeviceManifest.verify_review(enc,id,actor,digest),
      do: review(enc,id,actor,digest,choice)
  end

  def review(enc,id,actor,digest,choice) do
    Postgrex.transaction(Postgres, fn tx ->
      case S.rows(tx,"""
      SELECT m.digest,m.body,s.device_id,e.destination,e.patient_ref,e.encounter_ref
      FROM device_manifests m JOIN device_sessions s ON m.acquisition_id=s.id
      JOIN encounters c ON c.id=s.encounter_id JOIN encounter_exports e ON e.encounter_id=c.id
      WHERE s.id=$1 AND c.id=$2 AND c.clinician_actor=$3 AND c.closed_at IS NULL FOR UPDATE OF s,c
      """,[id,enc,actor]) do
        [[^digest,manifest,device,destination,patient,encounter]] ->
          case S.rows(tx,"SELECT digest,actor,choice FROM device_reviews WHERE acquisition_id=$1",[id]) do
            [[^digest,^actor,^choice]] -> :ok
            [] ->
              validate!(tx,manifest,choice)
              [[at]] = S.rows(tx,"INSERT INTO device_reviews(acquisition_id,digest,actor,choice) VALUES($1,$2,$3,$4) RETURNING reviewed_at",[id,digest,actor,choice])
              for code <- choice["metrics"] || [] do
                event = Enum.find_value(manifest["inventory"],fn r -> if r["event"]["event_id"] == choice["event_id"], do: r["event"] end)
                refs = %{"patient_ref"=>patient,"encounter_ref"=>encounter}
                with {:ok,evidence} <- DeviceMeasurement.derived(event,code,id,device,DateTime.to_iso8601(at)),
                     metric_id = S.hash("medfabric.metric.v1" <> <<0>> <> MedEx.CanonicalJSON.encode([id,event["event_id"],code])),
                     external = enc<>":"<>metric_id,
                     {:ok,resource} <- FhirClient.resource_checked(evidence,external,actor,refs) do
                  S.rows(tx,"INSERT INTO acquisitions(encounter_id,id,evidence,capture_profile,parent_acquisition_id,source_event_id) VALUES($1,$2,$3,'derived_device_metric',$4,$5)",[enc,metric_id,evidence,id,event["event_id"]])
                  Records.insert_acceptance(tx,[enc,metric_id,actor],[destination,external,resource])
                else
                  _ -> S.abort(tx,:ineligible_metric)
                end
              end
              :ok
            _ -> S.abort(tx,:review_conflict)
          end
        _ -> S.abort(tx,:review_changed)
      end
    end)
  end

  defp validate!(tx,m,c) do
    decision=c["decision"]
    metrics=c["metrics"] || []
    valid = is_list(metrics) and is_binary(c["note"]) and byte_size(c["note"])<=2000 and
      case decision do
        v when v in ["reject","repeat"] -> metrics==[]
        "complete" -> m["profile"]=="paired_exam" and m["defects"]==[] and metrics==[] and ranges?(m,c)
        "partial" -> m["profile"]=="paired_exam" and metrics==[] and ranges?(m,c) and
          m["defects"] != [] and c["acknowledged"]==m["defects"] and c["note"] != ""
        "accept_metrics" -> m["profile"]=="plx_spot_check" and is_list(metrics) and
          Enum.sort(metrics) in [["pulse_rate"],["spo2"],["pulse_rate","spo2"]] and
          Enum.any?(m["inventory"], &(&1["event"]["event_id"]==c["event_id"]))
        _ -> false
      end
    unless valid, do: S.abort(tx,:invalid_review)
  end

  defp ranges?(m,%{"ranges"=>ranges}) when is_list(ranges) and length(ranges) in 1..256 do
    Enum.all?(ranges, fn
      %{"stream"=>s,"first"=>first,"end"=>last} when is_binary(first) and is_binary(last) ->
        with {a,""} <- Integer.parse(first), {b,""} <- Integer.parse(last), true <- a<b do
          Enum.any?(get_in(m,["streams",s,"index","segments"]) || [], fn seg ->
            String.to_integer(seg["first_sample"])<=a and String.to_integer(seg["end_sample"])>=b
          end)
        else _ -> false end
      _ -> false
    end)
  end
  defp ranges?(_,_),do: false
end
