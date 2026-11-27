defmodule MedFabric.Store.Encounters do
  @moduledoc "Membership, browser session and independently optional export configuration."
  alias MedFabric.Store.AcquisitionSessions, as: S

  def open(
        db,
        %{"exam" => id, "patient_actor" => patient, "clinician_actor" => clinician} = entry
      ) do
    Postgrex.transaction(db, fn tx ->
      case S.rows(
             tx,
             "INSERT INTO encounters(id,patient_actor,clinician_actor) VALUES($1,$2,$3) ON CONFLICT(id) DO UPDATE SET id=EXCLUDED.id WHERE encounters.patient_actor=$2 AND encounters.clinician_actor=$3 AND encounters.closed_at IS NULL RETURNING id",
             [id, patient, clinician]
           ) do
        [[^id]] -> :ok
        _ -> S.abort(tx, :encounter_conflict)
      end

      if Enum.all?(~w(destination patient_ref encounter_ref), &is_binary(entry[&1])) do
        S.rows(
          tx,
          "INSERT INTO encounter_exports(encounter_id,destination,patient_ref,encounter_ref,conditional_create_qualified,qualification_ref) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(encounter_id) DO NOTHING",
          [
            id,
            entry["destination"],
            entry["patient_ref"],
            entry["encounter_ref"],
            entry["conditional_create_qualified"] == true,
            entry["qualification_ref"]
          ]
        )
      end

      :ok
    end)
  end

  def browser_session(db, id, enc, actor, role) when role in [:patient, :clinician] do
    Postgrex.transaction(db, fn tx ->
      S.authorize_encounter!(tx, enc, actor, role, :mutate)

      S.rows(
        tx,
        "INSERT INTO browser_sessions(id,encounter_id,actor,role,expires_at) VALUES($1,$2,$3,$4,clock_timestamp()+interval '1 hour') ON CONFLICT DO NOTHING",
        [id, enc, actor, to_string(role)]
      )

      :ok
    end)
  end

  def session_authorized?(db, id, enc, actor, role, access \\ :mutate),
    do:
      match?(
        {:ok, :ok},
        Postgrex.transaction(db, fn tx ->
          S.authorize_browser!(tx, id, enc, actor, role, access, :share)
        end)
      )

  def authority_remaining(db, id, enc, actor, role) do
    Postgrex.transaction(db, fn tx ->
      S.authorize_browser!(tx, id, enc, actor, role, :mutate, :share)

      [[remaining]] =
        S.rows(
          tx,
          "SELECT GREATEST(0,LEAST(30000,FLOOR(EXTRACT(EPOCH FROM (expires_at-clock_timestamp()))*1000)))::integer FROM browser_sessions WHERE id=$1",
          [id]
        )

      remaining
    end)
  end

  def close(db, enc, actor),
    do:
      Postgrex.transaction(db, fn tx ->
        S.authorize_encounter!(tx, enc, actor, :clinician, :mutate)
        S.rows(tx, "UPDATE encounters SET closed_at=clock_timestamp() WHERE id=$1", [enc])

        S.rows(
          tx,
          "UPDATE acquisition_sessions SET authority_state='closed',generation=generation+1 WHERE encounter_id=$1 AND authority_state='authorized'",
          [enc]
        )

        :ok
      end)

  def export(db, enc) do
    case S.rows(
           db,
           "SELECT destination,patient_ref,encounter_ref,conditional_create_qualified,qualification_ref FROM encounter_exports WHERE encounter_id=$1",
           [enc]
         ) do
      [[destination, patient, encounter, qualified, proof]] ->
        {:ok,
         %{
           destination: destination,
           refs: %{"patient_ref" => patient, "encounter_ref" => encounter},
           qualified: qualified,
           qualification_ref: proof
         }}

      [] ->
        {:error, :destination_missing}
    end
  end

  @doc "Repair future export preparation under current clinician access; existing outbox pins are never changed."
  def configure_export(db, enc, actor, config) do
    with {:ok, values} <- export_configuration(config) do
      Postgrex.transaction(db, fn tx ->
        S.authorize_encounter!(tx, enc, actor, :clinician, :read)
        S.writable!(tx)

        S.rows(
          tx,
          "INSERT INTO encounter_exports(encounter_id,destination,patient_ref,encounter_ref,conditional_create_qualified,qualification_ref) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(encounter_id) DO UPDATE SET destination=EXCLUDED.destination,patient_ref=EXCLUDED.patient_ref,encounter_ref=EXCLUDED.encounter_ref,conditional_create_qualified=EXCLUDED.conditional_create_qualified,qualification_ref=EXCLUDED.qualification_ref",
          [
            enc,
            values.destination,
            values.patient_ref,
            values.encounter_ref,
            values.qualified,
            values.qualification_ref
          ]
        )

        :ok
      end)
    end
  end

  defp export_configuration(config) when is_map(config) do
    required = ~w(destination patient_ref encounter_ref)
    allowed = required ++ ~w(conditional_create_qualified qualification_ref)
    qualified = Map.get(config, "conditional_create_qualified", false)
    proof = Map.get(config, "qualification_ref")

    with true <-
           Enum.all?(required, &Map.has_key?(config, &1)) and
             Enum.all?(Map.keys(config), &(&1 in allowed)),
         true <- is_boolean(qualified) and (is_nil(proof) or bounded_text?(proof, 256)),
         true <- not qualified or is_binary(proof),
         true <-
           reference?(config["patient_ref"], "Patient") and
             reference?(config["encounter_ref"], "Encounter"),
         destination when is_binary(destination) <- config["destination"],
         true <-
           bounded_text?(destination, 2048) and
             not String.contains?(destination, [" ", "\t", "\r", "\n"]),
         {:ok,
          %URI{scheme: scheme, host: host, port: port, userinfo: nil, query: nil, fragment: nil} =
            uri} <- URI.new(destination),
         true <-
           scheme in ["http", "https"] and is_binary(host) and byte_size(host) in 1..253 and
             port in 1..65_535 do
      {:ok,
       %{
         destination: URI.to_string(uri),
         patient_ref: config["patient_ref"],
         encounter_ref: config["encounter_ref"],
         qualified: qualified,
         qualification_ref: proof
       }}
    else
      _ -> {:error, :invalid_export_configuration}
    end
  end

  defp export_configuration(_), do: {:error, :invalid_export_configuration}

  defp bounded_text?(value, maximum),
    do:
      is_binary(value) and String.valid?(value) and
        byte_size(value) in 1..maximum and not String.contains?(value, <<0>>)

  defp reference?(value, type),
    do: is_binary(value) and Regex.match?(~r/\A#{type}\/[A-Za-z0-9.-]{1,64}\z/, value)
end
