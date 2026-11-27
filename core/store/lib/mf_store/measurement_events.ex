defmodule MedFabric.Store.MeasurementEvents do
  @moduledoc "Durable discrete evidence. Event acknowledgments bind exact identity and canonical fingerprint."
  alias MedFabric.Store.AcquisitionSessions, as: S

  def put(db, bind, event) do
    with :ok <- MedFabric.Domain.DeviceMeasurement.validate(event) do
      S.scoped(
        db,
        bind,
        fn tx, s ->
          unless s.profile == "plx_spot_check" and s.state in ["capturing", "finalizing"] and
                   event["acquisition_id"] == s.id and event["source_ref"] == s.principal and
                   event["boot_id"] == s.boot,
                 do: S.abort(tx, :inactive)

          id = event["event_id"]
          sequence = String.to_integer(event["gateway_sequence"])
          fingerprint = S.hash(MedEx.CanonicalJSON.encode(event))

          case S.rows(
                 tx,
                 "SELECT event_id,fingerprint FROM measurement_events WHERE acquisition_id=$1 AND (event_id=$2 OR seq=$3)",
                 [s.id, id, sequence]
               ) do
            [[^id, ^fingerprint]] ->
              %{event_id: id, fingerprint: fingerprint}

            [] ->
              if s.final_inventory && sequence >= String.to_integer(s.final_inventory["count"]),
                do: S.abort(tx, :inventory_conflict)

              S.rows(
                tx,
                "INSERT INTO measurement_events(acquisition_id,event_id,seq,fingerprint,body) VALUES($1,$2,$3,$4,$5)",
                [s.id, id, sequence, fingerprint, event]
              )

              %{event_id: id, fingerprint: fingerprint}

            _ ->
              S.abort(tx, :event_conflict)
          end
        end,
        :update
      )
    end
  end

  def inventory(tx, id),
    do:
      for(
        [body, hash, at] <-
          S.rows(
            tx,
            "SELECT body,fingerprint,received_at FROM measurement_events WHERE acquisition_id=$1 ORDER BY seq",
            [id]
          ),
        do: %{"event" => body, "fingerprint" => hash, "received_at" => DateTime.to_iso8601(at)}
      )
end
