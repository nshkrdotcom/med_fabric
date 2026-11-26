defmodule MedFabric.Exam.DeviceExpiry do
  @moduledoc "Releases an expired acquisition only after fencing its generation and quiescing live writers."
  use GenServer
  alias MedFabric.Exam.{DeviceIngress, DeviceRegistry}
  alias MedFabric.Store.DeviceCommands
  alias MedFabric.Store.DeviceSessions, as: S
  alias MedFabric.Store.Postgres

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  def init(nil) do
    Process.send_after(self(), :sweep, 2000)
    {:ok, nil}
  end

  def handle_info(:sweep, s) do
    ids =
      S.rows(
        Postgres,
        """
        SELECT s.id FROM device_sessions s JOIN device_credentials c USING(device_id)
        JOIN device_grants g USING(encounter_id,device_id,profile) JOIN encounters e ON e.id=s.encounter_id
        LEFT JOIN device_heartbeats h ON h.acquisition_id=s.id AND h.generation=s.generation
        WHERE s.phase='expiring' OR (s.phase IN ('capturing','awaiting_resume','finalizing') AND
          (greatest(coalesce(h.seen_at + interval '60 seconds',s.expires_at),s.expires_at) <= now()
           OR s.created_at+interval '30 minutes'<=now() OR c.revoked OR e.closed_at IS NOT NULL OR g.expires_at<=now()))
        """,
        []
      )

    for [id] <- ids, do: sweep_one(id)

    Process.send_after(self(), :sweep, 2000)
    {:noreply, s}
  end

  defp sweep_one(id) do
    # Recheck the deadline while acquiring the write fence. A racing heartbeat
    # must not turn an expired selection into a retrospective interruption.
    fenced =
      S.rows(
        Postgres,
        """
        UPDATE device_sessions s SET phase='expiring',generation=generation+1
        FROM encounters e,device_credentials c,device_grants g
        WHERE s.id=$1 AND e.id=s.encounter_id AND c.device_id=s.device_id AND
        (g.encounter_id,g.device_id,g.profile)=(s.encounter_id,s.device_id,s.profile)
        AND (s.phase='expiring' OR (s.phase IN ('capturing','awaiting_resume','finalizing') AND
        (greatest(s.expires_at,coalesce((SELECT seen_at+interval '60 seconds' FROM device_heartbeats h
          WHERE h.acquisition_id=s.id AND h.generation=s.generation),s.expires_at))<=now() OR
         c.revoked OR e.closed_at IS NOT NULL OR g.expires_at<=now() OR s.created_at+interval '30 minutes'<=now())))
        RETURNING s.encounter_id
        """,
        [id]
      )

    case fenced do
      [[enc]] ->
        if Enum.all?(~w(audio ecg), &quiescent?(id, &1)), do: finish_expiry(id, enc)

      _ ->
        :ok
    end
  end

  defp quiescent?(id, stream) do
    case Registry.lookup(DeviceRegistry, {id, stream}) do
      [{pid, _}] -> DeviceIngress.call(pid, :expire) == :ok
      [] -> true
    end
  end

  defp finish_expiry(id, enc) do
    if :ets.whereis(:mf_live_ecg) != :undefined, do: :ets.delete(:mf_live_ecg, id)

    Postgrex.transaction(Postgres, fn tx ->
      S.rows(
        tx,
        "UPDATE device_sessions SET phase='interrupted' WHERE id=$1 AND phase='expiring'",
        [id]
      )

      S.rows(
        tx,
        "UPDATE acquisitions SET state='interrupted' WHERE encounter_id=$1 AND id=$2 AND state='recording'",
        [enc, id]
      )

      DeviceCommands.close_pending(tx, id)

      S.fact(tx, id, "interrupted", %{
        "reason" => "authorization_or_resume_deadline",
        "trailing_loss" => "unknown"
      })
    end)
  end
end
