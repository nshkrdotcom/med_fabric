defmodule MedFabric.Store.Records do
  @moduledoc "Native evidence and atomic review, observation and delivery-intent persistence. No external mapping or network work."
  alias MedFabric.Domain.Evidence
  alias MedFabric.Store.AcquisitionSessions, as: S

  def member?(db, id, actor, role, access \\ :mutate)

  def member?(db, id, actor, role, access) when role in [:patient, :clinician] do
    case S.rows(
           db,
           "SELECT patient_actor,clinician_actor,closed_at FROM encounters WHERE id=$1",
           [id]
         ) do
      [[patient, clinician, closed]] ->
        actor == if(role == :patient, do: patient, else: clinician) and
          (access == :read or is_nil(closed))

      _ ->
        false
    end
  end

  def member?(_, _, _, _, _), do: false

  def put_manual(db, enc, id, actor, evidence) do
    Postgrex.transaction(db, fn tx ->
      S.authorize_encounter!(tx, enc, actor, :clinician, :mutate)
      S.writable!(tx)

      unless Evidence.validate(evidence) == :ok and
               evidence["provenance"]["actor"] == actor,
             do: S.abort(tx, :invalid_manual_evidence)

      digest = S.hash(MedEx.CanonicalJSON.encode(evidence))
      {:ok, at, _} = DateTime.from_iso8601(evidence["effective_at"])

      case S.rows(tx, "SELECT encounter_id,actor,body FROM manual_evidence WHERE id=$1", [id]) do
        [[^enc, ^actor, ^evidence]] ->
          id

        [] ->
          S.rows(
            tx,
            "INSERT INTO manual_evidence(id,encounter_id,actor,effective_at,body,digest) VALUES($1,$2,$3,$4,$5,$6)",
            [id, enc, actor, at, evidence, digest]
          )

          id

        _ ->
          S.abort(tx, :manual_evidence_conflict)
      end
    end)
  end

  def manual(db, enc, id, actor) do
    Postgrex.transaction(db, fn tx ->
      S.authorize_encounter!(tx, enc, actor, :clinician, :read, :share)

      case S.rows(tx, "SELECT body,digest FROM manual_evidence WHERE encounter_id=$1 AND id=$2", [
             enc,
             id
           ]) do
        [[body, digest]] ->
          %{
            kind: :manual,
            id: id,
            encounter: enc,
            body: body,
            digest: digest,
            verified: S.hash(MedEx.CanonicalJSON.encode(body)) == digest
          }

        _ ->
          S.abort(tx, :unknown_evidence)
      end
    end)
  end

  def accept_plan(db, plan) do
    Postgrex.transaction(db, fn tx ->
      enc = plan.source.encounter
      S.authorize_encounter!(tx, enc, plan.actor, :clinician, :read)

      case S.rows(
             tx,
             "SELECT id,request_content FROM reviews WHERE encounter_id=$1 AND actor=$2 AND request_id=$3 FOR UPDATE",
             [enc, plan.actor, plan.request_id]
           ) do
        [[id, content]] when content == plan.request ->
          outcome(tx, id)

        [] ->
          S.authorize_encounter!(tx, enc, plan.actor, :clinician, :mutate)
          S.writable!(tx)
          verify_source!(tx, plan.source)
          insert_decision(tx, plan)

        _ ->
          S.abort(tx, :request_conflict)
      end
    end)
  end

  defp verify_source!(tx, %{kind: :manual, id: id, encounter: enc, digest: digest, body: body}) do
    unless S.rows(
             tx,
             "SELECT body FROM manual_evidence WHERE encounter_id=$1 AND id=$2 AND digest=$3 FOR SHARE",
             [enc, id, digest]
           ) == [[body]], do: S.abort(tx, :evidence_changed)

    unless S.rows(tx, "SELECT id FROM reviews WHERE manual_id=$1", [id]) == [],
      do: S.abort(tx, :review_conflict)
  end

  defp verify_source!(tx, %{
         kind: :acquisition,
         id: id,
         encounter: enc,
         digest: digest,
         body: body
       }) do
    unless S.rows(
             tx,
             "SELECT body FROM acquisition_manifests WHERE encounter_id=$1 AND acquisition_id=$2 AND digest=$3 FOR SHARE",
             [enc, id, digest]
           ) == [[body]], do: S.abort(tx, :evidence_changed)

    unless S.rows(tx, "SELECT id FROM reviews WHERE acquisition_id=$1", [id]) == [],
      do: S.abort(tx, :review_conflict)
  end

  defp insert_decision(tx, p) do
    enc = p.source.encounter

    {acq, manifest, manual, manual_digest} =
      if p.source.kind == :manual,
        do: {nil, nil, p.source.id, p.source.digest},
        else: {p.source.id, p.source.digest, nil, nil}

    if p.repeat_id do
      [[kind, principal, profile]] =
        S.rows(
          tx,
          "SELECT source_kind,principal,profile FROM acquisitions WHERE id=$1 FOR UPDATE",
          [acq]
        )

      S.rows(
        tx,
        "INSERT INTO acquisitions(id,encounter_id,source_kind,principal,profile,state,parent_acquisition_id) VALUES($1,$2,$3,$4,$5,'reserved',$6)",
        [p.repeat_id, enc, kind, principal, profile, acq]
      )
    end

    S.rows(
      tx,
      "INSERT INTO reviews(id,encounter_id,actor,request_id,request_content,request_digest,choice,decided_at,acquisition_id,manifest_digest,manual_id,manual_digest,repeat_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
      [
        p.decision_id,
        enc,
        p.actor,
        p.request_id,
        p.request,
        p.request_digest,
        p.choice,
        p.decided_at,
        acq,
        manifest,
        manual,
        manual_digest,
        p.repeat_id
      ]
    )

    [[uuid]] =
      S.rows(tx, "SELECT deployment_uuid::text FROM deployment_identity WHERE singleton", [])

    Enum.each(p.observations, fn observation ->
      {:ok, at, _} = DateTime.from_iso8601(observation["effective_at"])

      S.rows(
        tx,
        "INSERT INTO observations(id,encounter_id,decision_id,actor,effective_at,body,digest) VALUES($1,$2,$3,$4,$5,$6,$7)",
        [observation["id"], enc, p.decision_id, p.actor, at, observation, observation["digest"]]
      )

      if observation["export_required"] do
        S.rows(
          tx,
          "INSERT INTO outbox_deliveries(id,encounter_id,observation_id,identifier_system,identifier_value) VALUES($1,$2,$1,$3,$1)",
          [observation["id"], enc, "urn:uuid:" <> uuid]
        )
      end
    end)

    outcome(tx, p.decision_id)
  end

  defp outcome(tx, id) do
    [[at, repeat]] = S.rows(tx, "SELECT decided_at,repeat_id FROM reviews WHERE id=$1", [id])

    observations =
      for [oid] <-
            S.rows(tx, "SELECT id FROM observations WHERE decision_id=$1 ORDER BY id", [id]),
          do: oid

    %{decision_id: id, decided_at: at, observations: observations, repeat_id: repeat}
  end

  def list(db, enc, actor) do
    Postgrex.transaction(db, fn tx ->
      S.authorize_encounter!(tx, enc, actor, :clinician, :read, :share)

      for [id, body, digest, decision, observation, status, remote] <-
            S.rows(
              tx,
              "SELECT m.id,m.body,m.digest,r.id,o.id,d.status,d.remote_ref FROM manual_evidence m LEFT JOIN reviews r ON r.manual_id=m.id LEFT JOIN observations o ON o.decision_id=r.id LEFT JOIN outbox_deliveries d ON d.observation_id=o.id WHERE m.encounter_id=$1 ORDER BY m.effective_at DESC LIMIT 100",
              [enc]
            ),
          do: %{
            id: id,
            evidence: body,
            digest: digest,
            decision: decision,
            observation: observation,
            status: status,
            remote: remote
          }
    end)
  end
end
