defmodule MedFabric.Store.DeviceSessions do
  @moduledoc "Encounter-scoped device grants, transport generations and immutable source bindings."
  alias MedFabric.Store.Postgres

  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def nonce, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  def rows(tx, sql, args), do: Postgrex.query!(tx, sql, args).rows
  def abort(tx, why), do: Postgrex.rollback(tx, why)

  def enroll(id, token) when byte_size(token) >= 32 do
    rows(Postgres, """
    INSERT INTO device_credentials(device_id,token_hash) VALUES ($1,$2)
    ON CONFLICT(device_id) DO UPDATE SET token_hash=EXCLUDED.token_hash
    WHERE device_credentials.token_hash=EXCLUDED.token_hash RETURNING device_id
    """, [id,hash(token)]) == [[id]]
  end

  def authorize(enc, device, profile, site, actor) when profile in ["paired_exam","plx_spot_check"] and byte_size(site) in 1..100 do
    case rows(Postgres, """
    INSERT INTO device_grants SELECT id,$2,$3,$4,now()+interval '2 hours',$5 FROM encounters
    WHERE id=$1 AND clinician_actor=$5 AND closed_at IS NULL
    ON CONFLICT(encounter_id,device_id,profile) DO UPDATE SET site=$4,expires_at=EXCLUDED.expires_at,authorized_by=$5
    RETURNING encounter_id
    """, [enc,device,profile,site,actor]) do
      [[^enc]] -> :ok
      _ -> {:error,:denied}
    end
  end

  def authenticate(token) do
    case rows(Postgres,"SELECT device_id FROM device_credentials WHERE token_hash=$1 AND NOT revoked",[hash(token)]) do
      [[id]] -> {:ok,id}
      _ -> {:error,:denied}
    end
  end

  @live "s.created_at+interval '30 minutes'>now() AND GREATEST(s.expires_at,coalesce((SELECT seen_at+interval '60 seconds' FROM device_heartbeats h WHERE h.acquisition_id=s.id AND h.generation=s.generation),s.expires_at))>now()"

  def reserve(device, enc, id, profile, boot, descriptors) do
    lease = nonce()
    Postgrex.transaction(Postgres, fn tx ->
      site = case rows(tx, """
      SELECT g.site FROM device_grants g JOIN encounters e ON e.id=g.encounter_id
      JOIN device_credentials c ON c.device_id=g.device_id WHERE g.encounter_id=$1 AND g.device_id=$2
      AND g.profile=$3 AND e.closed_at IS NULL AND NOT c.revoked AND g.expires_at>now() FOR UPDATE OF e,g
      """,[enc,device,profile]) do
        [[site]] -> site
        _ -> abort(tx,:grant_denied)
      end
      case rows(tx,"SELECT device_id,encounter_id,profile,boot,descriptors,phase,(" <> @live <> ") FROM device_sessions s WHERE id=$1 FOR UPDATE",[id]) do
        [] ->
          if rows(tx,"INSERT INTO acquisitions(encounter_id,id,producer,state,capture_profile) VALUES($1,$2,$3,'recording',$4) ON CONFLICT DO NOTHING RETURNING id",[enc,id,device,profile]) == [], do: abort(tx,:active_slot_busy)
          previous=case rows(tx,"SELECT s.id FROM device_sessions s JOIN device_reviews r ON r.acquisition_id=s.id WHERE s.encounter_id=$1 AND s.device_id=$2 AND s.profile=$3 AND r.choice->>'decision'='repeat' AND NOT EXISTS (SELECT 1 FROM device_sessions n WHERE n.repeat_of=s.id) ORDER BY r.reviewed_at DESC LIMIT 1",[enc,device,profile]) do
            [[prior]] -> prior
            [] -> nil
          end
          rows(tx,"INSERT INTO device_sessions(id,encounter_id,device_id,profile,boot,site,descriptors,lease_hash,phase,expires_at,repeat_of) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'capturing',now()+interval '60 seconds',$9)",[id,enc,device,profile,boot,site,descriptors,hash(lease),previous])
        [[^device,^enc,^profile,^boot,^descriptors,phase,true]] when phase in ["capturing","awaiting_resume","finalizing"] -> :ok
        [[^device,^enc,^profile,^boot,^descriptors,"sealed",_]] -> :ok
        _ -> abort(tx,:resume_conflict)
      end
      [[generation,phase]] = rows(tx,"UPDATE device_sessions SET phase=CASE WHEN phase='awaiting_resume' THEN 'capturing' ELSE phase END,generation=generation+1,lease_hash=$2,expires_at=now()+interval '60 seconds' WHERE id=$1 RETURNING generation,phase",[id,hash(lease)])
      %{id: id, device: device, encounter: enc, profile: profile, boot: boot, descriptors: descriptors, lease: lease, generation: generation, phase: phase}
    end)
  end

  # SHARE locks are compatible across streams. A generation rotation, revocation
  # or finalization serializes against admitted effects including the file checkpoint.
  def scoped(bind, fun, mode \\ :share) do
    Postgrex.transaction(Postgres, fn tx ->
      lock = if mode == :update, do: "FOR UPDATE OF s FOR SHARE OF g,e,c", else: "FOR SHARE OF s,g,e,c"
      case rows(tx, """
      SELECT s.phase,s.descriptors,s.encounter_id,s.boot,s.profile,s.site FROM device_sessions s
      JOIN device_grants g USING(encounter_id,device_id,profile) JOIN encounters e ON e.id=s.encounter_id
      JOIN device_credentials c USING(device_id) WHERE s.id=$1 AND s.device_id=$2
      AND s.generation=$3 AND s.lease_hash=$4 AND NOT c.revoked AND g.expires_at>now()
      AND e.closed_at IS NULL AND (s.phase='sealed' OR (
      """ <> @live <> ")) " <> lock,[bind.id,bind.device,bind.generation,hash(bind.lease)]) do
        [[phase,desc,enc,boot,profile,site]] -> fun.(tx,%{phase: phase, descriptors: desc, encounter: enc, boot: boot, profile: profile, site: site})
        _ -> abort(tx,:stale_lease)
      end
    end, timeout: 40_000)
  end

  def fact(tx,id,kind,body), do: rows(tx,"INSERT INTO device_facts(acquisition_id,kind,fact) VALUES($1,$2,$3)",[id,kind,body])
  def facts(tx,id), do: for [kind,body,at] <- rows(tx,"SELECT kind,fact,recorded_at FROM device_facts WHERE acquisition_id=$1 ORDER BY ordinal",[id]), do: %{"type"=>kind,"body"=>body,"received_at"=>DateTime.to_iso8601(at)}

  def disconnected(bind) do
    rows(Postgres,"UPDATE device_sessions SET phase='awaiting_resume' WHERE id=$1 AND device_id=$2 AND generation=$3 AND lease_hash=$4 AND phase='capturing'",[bind.id,bind.device,bind.generation,hash(bind.lease)])
    :ok
  end

  def heartbeat(bind) do
    scoped(bind,fn tx,_ ->
      rows(tx,"INSERT INTO device_heartbeats(acquisition_id,generation) VALUES($1,$2) ON CONFLICT(acquisition_id) DO UPDATE SET generation=$2,seen_at=clock_timestamp(),count=device_heartbeats.count+1",[bind.id,bind.generation])
      :ok
    end)
  end
end
