defmodule MedFabric.Store.Records do
  @moduledoc "Persists typed evidence and atomically accepts it with its export intent."

  def open(db, id, patient, clinician) do
    Postgrex.query(
      db,
      """
      INSERT INTO encounters (id, patient_actor, clinician_actor) VALUES ($1,$2,$3)
      ON CONFLICT (id) DO UPDATE SET id = EXCLUDED.id
      WHERE encounters.patient_actor = EXCLUDED.patient_actor
        AND encounters.clinician_actor = EXCLUDED.clinician_actor
        AND encounters.closed_at IS NULL
      RETURNING id
      """,
      [id, patient, clinician]
    )
    |> written(:encounter_conflict)
  end

  def member?(db, id, actor, role) when role in [:patient, :clinician] do
    match?(
      {:ok, %{rows: [[^id]]}},
      Postgrex.query(
        db,
        """
        SELECT id FROM encounters
        WHERE id = $1 AND closed_at IS NULL
          AND CASE WHEN $3::text = 'patient' THEN patient_actor ELSE clinician_actor END = $2
        """,
        [id, actor, Atom.to_string(role)]
      )
    )
  end

  def ready(db, encounter, acquisition, evidence) do
    case Postgrex.transaction(db, &ready_locked(&1, encounter, acquisition, evidence)) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp ready_locked(tx, encounter, acquisition, evidence) do
    case Postgrex.query!(
           tx,
           "SELECT id FROM encounters WHERE id=$1 AND closed_at IS NULL FOR UPDATE",
           [encounter]
         ).rows do
      [[^encounter]] -> put_evidence(tx, encounter, acquisition, evidence)
      [] -> Postgrex.rollback(tx, :encounter_unavailable)
    end
  end

  defp put_evidence(tx, encounter, acquisition, evidence) do
    case Postgrex.query!(
           tx,
           """
           INSERT INTO acquisitions AS a (encounter_id,id,evidence) VALUES ($1,$2,$3)
           ON CONFLICT (encounter_id,id) DO UPDATE
           SET conflict = a.conflict OR (a.evidence <> EXCLUDED.evidence AND NOT EXISTS (
             SELECT 1 FROM observations o WHERE o.encounter_id=a.encounter_id AND o.acquisition_id=a.id
           ))
           WHERE a.state='ready'
           RETURNING conflict, evidence=$3
           """,
           [encounter, acquisition, evidence]
         ).rows do
      [[false, true]] -> :ok
      _ -> {:error, :evidence_conflict}
    end
  end

  def reserve(db, encounter, id, producer) do
    Postgrex.query(
      db,
      """
      INSERT INTO acquisitions (encounter_id,id,producer,state)
      SELECT id,$2,$3,'recording' FROM encounters
      WHERE id=$1 AND patient_actor=$3 AND closed_at IS NULL
      ON CONFLICT DO NOTHING
      """,
      [encounter, id, producer]
    )
    |> written(:capture_unavailable)
  end

  def first_frame(db, encounter, id, source, at) do
    Postgrex.query(
      db,
      """
      UPDATE acquisitions SET capture_source=$3,first_received_at=$4
      WHERE encounter_id=$1 AND id=$2 AND state='recording' AND first_received_at IS NULL
      """,
      [encounter, id, source, at]
    )
    |> written(:capture_unavailable)
  end

  def pending_encounters(db, configured_ids) do
    case Postgrex.query(db, """
           SELECT encounter_id FROM acquisitions
           WHERE state='recording' AND encounter_id=ANY($1::text[])
           """, [configured_ids]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [id] -> id end)}
      error -> error
    end
  end

  def pending(db, encounter) do
    case Postgrex.query(
           db,
           """
           SELECT id,producer,capture_source,first_received_at FROM acquisitions
           WHERE encounter_id=$1 AND state='recording'
           """,
           [encounter]
         ) do
      {:ok, %{rows: [[id, actor, source, at]]}} ->
        {:ok, %{id: id, producer: actor, source: source, first_received_at: at}}

      {:ok, %{rows: []}} -> {:ok, nil}
      error -> error
    end
  end

  def interrupt(db, encounter, id) do
    Postgrex.query(
      db,
      "UPDATE acquisitions SET state='interrupted' WHERE encounter_id=$1 AND id=$2 AND state='recording'",
      [encounter, id]
    )
    |> written(:capture_unavailable)
  end

  def complete(db, encounter, id, evidence) do
    # A repeat finish may confirm only the same durable evidence.
    Postgrex.query(
      db,
      """
      UPDATE acquisitions SET state='ready',evidence=$3,producer=NULL,capture_source=NULL,first_received_at=NULL
      WHERE encounter_id=$1 AND id=$2 AND (
        (state='recording' AND first_received_at IS NOT NULL)
        OR (state='ready' AND evidence=$3)
      )
      """,
      [encounter, id, evidence]
    )
    |> written(:evidence_conflict)
  end

  def recording_status(db, encounter, id) do
    case Postgrex.query(
           db,
           """
           SELECT state FROM acquisitions WHERE encounter_id=$1 AND id=$2
           AND (state <> 'ready' OR evidence->>'kind'='audio_pcm16_wav')
           """,
           [encounter, id]
         ) do
      {:ok, %{rows: [[state]]}} -> {:ok, state}
      {:ok, %{rows: []}} -> {:error, :not_found}
      error -> error
    end
  end

  @review_query """
  SELECT a.id, a.evidence, a.conflict, o.actor, d.remote_ref, d.last_error
  FROM acquisitions a
  LEFT JOIN observations o ON (o.encounter_id,o.acquisition_id)=(a.encounter_id,a.id)
  LEFT JOIN outbox_deliveries d ON (d.encounter_id,d.acquisition_id)=(a.encounter_id,a.id)
  WHERE a.encounter_id=$1 AND a.state='ready'
  """

  def list(db, encounter) do
    case Postgrex.query(db, @review_query <> " ORDER BY a.id", [encounter]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &review_row/1)}
      error -> error
    end
  end

  def get(db, encounter, acquisition) do
    case Postgrex.query(db, @review_query <> " AND a.id=$2", [encounter, acquisition]) do
      {:ok, %{rows: [row]}} -> {:ok, review_row(row)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      error -> error
    end
  end

  defp review_row([id, evidence, conflict, actor, remote, error]) do
    %{id: id, evidence: evidence, conflict: conflict, actor: actor, remote: remote, error: error}
  end

  def accept(db, encounter, acquisition, actor, evidence, destination, external_id, resource) do
    Postgrex.transaction(db, fn tx ->
      case Postgrex.query!(
             tx,
             """
             WITH authorized AS MATERIALIZED (
               SELECT id FROM encounters WHERE id=$1 AND clinician_actor=$3 AND closed_at IS NULL FOR UPDATE
             )
             SELECT a.evidence, a.conflict FROM authorized e JOIN acquisitions a ON e.id=a.encounter_id
             WHERE a.id=$2 AND a.state='ready' FOR UPDATE OF a
             """,
             [encounter, acquisition, actor]
           ).rows do
        [[^evidence, false]] ->
          insert_acceptance(tx, [encounter, acquisition, actor], [
            destination,
            external_id,
            resource
          ])

        _ ->
          Postgrex.rollback(tx, :review_changed)
      end
    end)
  end

  defp insert_acceptance(tx, [encounter, acquisition, _] = observation, delivery) do
    case Postgrex.query!(
           tx,
           """
           INSERT INTO observations (encounter_id,acquisition_id,actor) VALUES ($1,$2,$3)
           ON CONFLICT DO NOTHING
           """,
           observation
         ).num_rows do
      1 ->
        Postgrex.query!(
          tx,
          """
          INSERT INTO outbox_deliveries (encounter_id,acquisition_id,destination,external_id,resource)
          VALUES ($1,$2,$3,$4,$5)
          """,
          [encounter, acquisition | delivery]
        )

        :ok

      0 ->
        :ok
    end
  end

  def delivery(db, encounter, acquisition) do
    case Postgrex.query(
           db,
           """
           SELECT destination, resource, remote_ref FROM outbox_deliveries
           WHERE encounter_id=$1 AND acquisition_id=$2
           """,
           [encounter, acquisition]
         ) do
      {:ok, %{rows: [[destination, resource, remote]]}} -> {:ok, destination, resource, remote}
      {:ok, %{rows: []}} -> {:error, :review_required}
      error -> error
    end
  end

  def delivery_result(db, encounter, acquisition, result) do
    {ref, error} =
      case result do
        {:ok, %{remote_ref: ref}} -> {ref, nil}
        {:error, _} -> {nil, "delivery_failed"}
      end

    case Postgrex.query(
           db,
           """
           UPDATE outbox_deliveries SET remote_ref=coalesce(remote_ref,$3),
             last_error=CASE WHEN coalesce(remote_ref,$3) IS NULL THEN $4 END
           WHERE encounter_id=$1 AND acquisition_id=$2 AND (remote_ref IS NULL OR remote_ref=$3 OR $3 IS NULL)
           RETURNING remote_ref
           """,
           [encounter, acquisition, ref, error]
         ) do
      {:ok, %{rows: [[nil]]}} -> result
      {:ok, %{rows: [[_]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :delivery_state_changed}
      error -> error
    end
  end

  defp written({:ok, %{num_rows: 1}}, _), do: :ok
  defp written({:ok, %{num_rows: 0}}, reason), do: {:error, reason}
  defp written(error, _), do: error
end
