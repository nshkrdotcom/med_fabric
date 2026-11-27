defmodule MedFabric.Store.DeviceSessions do
  @moduledoc "Explicit database operations for enrolled device credentials and encounter grants."
  alias MedFabric.Store.AcquisitionSessions, as: S

  def enroll(db, id, token) when is_binary(token) and byte_size(token) in 32..4096 do
    S.rows(db, "INSERT INTO device_credentials(device_id,token_hash) VALUES($1,$2) ON CONFLICT(device_id) DO UPDATE SET token_hash=EXCLUDED.token_hash WHERE device_credentials.token_hash=EXCLUDED.token_hash RETURNING device_id", [id,S.hash(token)]) == [[id]]
  end
  def enroll(_, _, _), do: false

  def authenticate(db, token) when is_binary(token) and byte_size(token) in 32..4096 do
    case S.rows(db, "SELECT device_id FROM device_credentials WHERE token_hash=$1 AND NOT revoked", [S.hash(token)]) do
      [[id]] -> {:ok, id}
      _ -> {:error, :denied}
    end
  end
  def authenticate(_, _), do: {:error, :denied}

  def authorize(db, enc, device, profile, site, actor)
      when profile in ["paired_exam","plx_spot_check"] and is_binary(site) and byte_size(site) in 1..100 do
    Postgrex.transaction(db, fn tx ->
      S.authorize_encounter!(tx,enc,actor,:clinician,:mutate)
      S.rows(tx, "INSERT INTO device_grants(encounter_id,device_id,profile,site,expires_at,authorized_by) VALUES($1,$2,$3,$4,clock_timestamp()+interval '2 hours',$5) ON CONFLICT(encounter_id,device_id,profile) DO UPDATE SET site=$4,expires_at=EXCLUDED.expires_at,authorized_by=$5,revoked=false", [enc,device,profile,site,actor])
      :ok
    end)
  end
  def authorize(_,_,_,_,_,_), do: {:error,:denied}

  def list(db), do: for [id] <- S.rows(db,"SELECT device_id FROM device_credentials WHERE NOT revoked ORDER BY device_id",[]), do: id

  def revoke(db, enc, device, profile, actor) do
    Postgrex.transaction(db, fn tx ->
      S.authorize_encounter!(tx,enc,actor,:clinician,:mutate)
      S.rows(tx,"UPDATE device_grants SET revoked=true WHERE encounter_id=$1 AND device_id=$2 AND profile=$3",[enc,device,profile])
      S.rows(tx,"UPDATE acquisition_sessions SET authority_state='revoked',generation=generation+1 WHERE encounter_id=$1 AND device_id=$2 AND profile=$3 AND authority_state='authorized'",[enc,device,profile])
      :ok
    end)
  end
end
