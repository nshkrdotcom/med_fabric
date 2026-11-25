defmodule MedFabric.Store.MeasurementEvents do
  @moduledoc "Durable gateway inventory with idempotent exact replay and terminal conflict audit."
  alias MedFabric.Store.DeviceSessions, as: S

  def put(bind, event, fingerprint) do
    S.scoped(
      bind,
      fn tx, session ->
        if session.profile != "plx_spot_check", do: S.abort(tx, :wrong_profile)
        id = event["event_id"]
        seq = String.to_integer(event["gateway_sequence"])

        case S.rows(
               tx,
               "SELECT event_id,fingerprint FROM measurement_events WHERE acquisition_id=$1 AND (event_id=$2 OR seq=$3)",
               [bind.id, id, seq]
             ) do
          [[^id, ^fingerprint]] ->
            :durable

          [] when session.phase in ["capturing", "finalizing"] ->
            put_new(tx, bind.id, id, seq, event, fingerprint)

          _ ->
            quarantine(tx, bind.id, id, fingerprint)
        end
      end,
      :update
    )
  end

  defp put_new(tx, acquisition, id, seq, event, fingerprint) do
    final = S.rows(tx, "SELECT final_inventory FROM device_sessions WHERE id=$1", [acquisition])

    if seq >= 10_000 or outside_inventory?(final, seq) do
      quarantine(tx, acquisition, id, fingerprint)
    else
      S.rows(
        tx,
        "INSERT INTO measurement_events(acquisition_id,event_id,seq,fingerprint,body) VALUES($1,$2,$3,$4,$5)",
        [acquisition, id, seq, fingerprint, event]
      )

      :durable
    end
  end

  defp outside_inventory?([[%{"count" => count}]], seq), do: seq >= String.to_integer(count)
  defp outside_inventory?(_, _), do: false

  defp quarantine(tx, acquisition, id, fingerprint) do
    S.fact(tx, acquisition, "quarantine", %{"id" => id, "fingerprint" => fingerprint})
    :quarantined
  end

  def inventory(tx, id) do
    for [body, hash, at] <-
          S.rows(
            tx,
            "SELECT body,fingerprint,received_at FROM measurement_events WHERE acquisition_id=$1 ORDER BY seq",
            [id]
          ),
        do: %{"event" => body, "fingerprint" => hash, "received_at" => DateTime.to_iso8601(at)}
  end
end
