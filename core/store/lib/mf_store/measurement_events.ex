defmodule MedFabric.Store.MeasurementEvents do
  @moduledoc "Durable gateway inventory with idempotent exact replay and terminal conflict audit."
  alias MedFabric.Store.DeviceSessions, as: S

  def put(bind, event, fingerprint) do
    S.scoped(bind, fn tx, session ->
      if session.profile  !=  "plx_spot_check", do: S.abort(tx,:wrong_profile)
      id = event["event_id"]
      seq = String.to_integer(event["gateway_sequence"])
      case S.rows(tx,"SELECT event_id,fingerprint FROM measurement_events WHERE acquisition_id=$1 AND (event_id=$2 OR seq=$3)",[bind.id,id,seq]) do
        [[^id,^fingerprint]] -> :durable
        [] when session.phase in ["capturing","finalizing"] ->
          final = S.rows(tx,"SELECT final_inventory FROM device_sessions WHERE id=$1",[bind.id])
          if seq >= 10_000 or match?([[ %{"count" => _} ]], final) and seq >= String.to_integer(hd(hd(final))["count"]) do
            S.fact(tx,bind.id,"quarantine",%{"id"=>id,"fingerprint"=>fingerprint})
            :quarantined
          else
            S.rows(tx,"INSERT INTO measurement_events(acquisition_id,event_id,seq,fingerprint,body) VALUES($1,$2,$3,$4,$5)",[bind.id,id,seq,fingerprint,event])
            :durable
          end
        _ ->
          S.fact(tx,bind.id,"quarantine",%{"id"=>id,"fingerprint"=>fingerprint})
          :quarantined
      end
    end,:update)
  end

  def inventory(tx,id) do
    for [body,hash,at] <- S.rows(tx,"SELECT body,fingerprint,received_at FROM measurement_events WHERE acquisition_id=$1 ORDER BY seq",[id]),
      do: %{"event"=>body,"fingerprint"=>hash,"received_at"=>DateTime.to_iso8601(at)}
  end
end
