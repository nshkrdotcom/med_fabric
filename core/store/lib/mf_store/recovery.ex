defmodule MedFabric.Store.Recovery do
  @moduledoc "Checksummed current-revision recovery inventory. Missing later native facts never become an operator-approved absence."
  alias MedEx.{CanonicalJSON, Receipt}
  alias MedFabric.Store.AcquisitionSessions, as: S
  @maximum_inventory 16_777_216

  def block(db, cut_point) when is_binary(cut_point) do
    if lsn?(cut_point) do
      Postgrex.transaction(db, fn tx ->
        S.rows(tx, "SELECT singleton FROM deployment_identity WHERE singleton FOR UPDATE", [])

        S.rows(
          tx,
          "UPDATE deployment_identity SET recovery_state='blocked',restored_cut_point=$1,reconciliation_digest=NULL WHERE singleton",
          [cut_point]
        )

        :ok
      end)
    else
      {:error, :invalid_cut_point}
    end
  end

  @doc "Capture the complete quiesced authority catalog to preserve with a current DB/WAL backup; never a claim that an older backup is current."
  def inventory(db) do
    Postgrex.transaction(db, fn tx ->
      [[uuid, revision, migration, state]] =
        S.rows(
          tx,
          "SELECT deployment_uuid::text,revision,migration_sha256,recovery_state FROM deployment_identity WHERE singleton FOR UPDATE",
          []
        )

      unless state == "blocked", do: S.abort(tx, :admissions_must_be_blocked)
      require_quiesced!(tx)
      [[lsn]] = S.rows(tx, "SELECT pg_current_wal_lsn()::text", [])

      value = %{
        "schema" => "medfabric.recovery-inventory.v2",
        "scope" => "whole_deployment",
        "deployment_uuid" => uuid,
        "revision" => to_string(revision),
        "migration_sha256" => migration,
        "cut_point" => lsn,
        "catalog" => catalog(tx)
      }

      bytes = CanonicalJSON.encode(value)
      if byte_size(bytes) > @maximum_inventory, do: S.abort(tx, :inventory_capacity)
      %{bytes: bytes, digest: S.hash(bytes), cut_point: lsn}
    end)
  end

  def inspect_inventory(bytes, digest)
      when is_binary(bytes) and byte_size(bytes) <= @maximum_inventory do
    with true <- S.hash(bytes) == digest,
         {:ok,
          %{
            "schema" => "medfabric.recovery-inventory.v2",
            "scope" => "whole_deployment",
            "revision" => "2"
          } = value} <- CanonicalJSON.decode(bytes),
         true <-
           Enum.sort(Map.keys(value)) ==
             ~w(catalog cut_point deployment_uuid migration_sha256 revision schema scope),
         true <- CanonicalJSON.encode(value) == bytes and lsn?(value["cut_point"]) do
      {:ok, value}
    else
      _ -> {:error, :invalid_authority_inventory}
    end
  end

  def inspect_inventory(_, _), do: {:error, :invalid_authority_inventory}

  @doc "Read the explicit artifact identities needed by the host to obtain actual recovery proofs while admissions remain blocked."
  def artifact_catalog(db) do
    Postgrex.transaction(db, fn tx ->
      unless S.rows(
               tx,
               "SELECT recovery_state FROM deployment_identity WHERE singleton FOR SHARE",
               []
             ) == [["blocked"]], do: S.abort(tx, :admissions_must_be_blocked)

      require_quiesced!(tx)

      acquisitions =
        for [id, descriptors] <-
              S.rows(
                tx,
                "SELECT a.id,COALESCE(s.descriptors,'{}'::jsonb) FROM acquisitions a LEFT JOIN acquisition_sessions s USING(id) ORDER BY a.id",
                []
              ),
            do: %{id: id, descriptors: descriptors}

      attempts =
        for [id, stream, fence, receipt, digest, descriptor] <-
              S.rows(
                tx,
                "SELECT a.acquisition_id,a.stream,a.fence,a.receipt,a.index_digest,s.descriptors->a.stream FROM stream_attempts a JOIN acquisition_sessions s ON s.id=a.acquisition_id ORDER BY a.acquisition_id,a.stream,a.generation",
                []
              ),
            do: %{
              acquisition: id,
              stream: stream,
              fence: fence,
              receipt: receipt,
              index_digest: digest,
              descriptor: descriptor
            }

      manifests =
        for [id, digest, body] <-
              S.rows(
                tx,
                "SELECT acquisition_id,digest,body FROM acquisition_manifests ORDER BY acquisition_id",
                []
              ),
            do: %{acquisition: id, digest: digest, body: body}

      %{acquisitions: acquisitions, attempts: attempts, manifests: manifests}
    end)
  end

  @doc "Resume only the exact later authoritative catalog, with actual root-bound recovered journals and installed manifest bytes. No reconstruction from remote records."
  def reconcile(db, bytes, digest, proof) do
    with {:ok, inventory} <- inspect_inventory(bytes, digest), :ok <- root_proof(proof) do
      Postgrex.transaction(db, fn tx ->
        reconcile_inventory(tx, inventory, digest, proof)
      end)
    end
  end

  defp reconcile_inventory(tx, inventory, digest, proof) do
    [[uuid, cut, state, migration]] =
      S.rows(
        tx,
        "SELECT deployment_uuid::text,restored_cut_point,recovery_state,migration_sha256 FROM deployment_identity WHERE singleton FOR UPDATE",
        []
      )

    unless state == "blocked" and inventory["deployment_uuid"] == uuid and
             inventory["migration_sha256"] == migration and lsn?(cut),
           do: S.abort(tx, :restore_identity_conflict)

    unless S.rows(tx, "SELECT $1::text::pg_lsn >= $2::text::pg_lsn", [
             inventory["cut_point"],
             cut
           ]) == [
             [true]
           ],
           do: S.abort(tx, :authority_precedes_restored_cut_point)

    require_quiesced!(tx)

    unless catalog(tx) == inventory["catalog"],
      do: S.abort(tx, :missing_or_changed_post_cut_point_facts)

    verify_artifacts!(tx, proof)

    S.rows(
      tx,
      "UPDATE deployment_identity SET recovery_state='current',reconciliation_digest=$1 WHERE singleton",
      [digest]
    )

    digest
  end

  defp require_quiesced!(tx) do
    unless S.rows(
             tx,
             "SELECT count(*) FROM stream_attempts WHERE attempt_state IN ('open','unknown')",
             []
           ) == [[0]] and
             S.rows(
               tx,
               "SELECT count(*) FROM acquisitions WHERE state IN ('reserved','capturing','finalizing','staged')",
               []
             ) == [[0]] and
             S.rows(tx, "SELECT count(*) FROM outbox_deliveries WHERE status='dispatching'", []) ==
               [[0]],
           do: S.abort(tx, :effects_not_settled)
  end

  # Full native bodies and append-only attempt history prevent absent post-cut-point
  # acquisitions, decisions or possibly sent intents from masquerading as absence.
  defp catalog(tx) do
    queries = [
      {"encounters",
       "SELECT id,patient_actor,clinician_actor,closed_at FROM encounters ORDER BY id"},
      {"acquisitions",
       "SELECT id,encounter_id,source_kind,principal,profile,state,parent_acquisition_id,created_at FROM acquisitions ORDER BY id"},
      {"sessions",
       "SELECT id,encounter_id,source_kind,principal,profile,boot,site,descriptors,generation,authority_state,final_inventory,frozen_at,frozen_generation FROM acquisition_sessions ORDER BY id"},
      {"attempts",
       "SELECT acquisition_id,stream,number,generation,fence,attempt_state,receipt,sealed_index,index_digest FROM stream_attempts ORDER BY acquisition_id,stream,generation"},
      {"facts",
       "SELECT ordinal,acquisition_id,kind,fact,recorded_at FROM acquisition_facts ORDER BY ordinal"},
      {"transport",
       "SELECT fence,sequence,raw_digest,received_at FROM transport_observations ORDER BY fence,sequence"},
      {"events",
       "SELECT acquisition_id,event_id,seq,fingerprint,body,received_at FROM measurement_events ORDER BY acquisition_id,seq"},
      {"manifests",
       "SELECT acquisition_id,encounter_id,digest,body,promoted_at FROM acquisition_manifests ORDER BY acquisition_id"},
      {"manual",
       "SELECT id,encounter_id,actor,effective_at,body,digest FROM manual_evidence ORDER BY id"},
      {"reviews",
       "SELECT id,encounter_id,actor,request_id,request_content,request_digest,choice,decided_at,acquisition_id,manifest_digest,manual_id,manual_digest,repeat_id FROM reviews ORDER BY id"},
      {"observations",
       "SELECT id,encounter_id,decision_id,actor,effective_at,body,digest FROM observations ORDER BY id"},
      {"intents",
       "SELECT id,encounter_id,observation_id,identifier_system,identifier_value,status,destination,references_json,mapping_version,encode(resource_bytes,'base64'),fingerprint,conditional_qualified,qualification_ref,remote_ref,proof FROM outbox_deliveries ORDER BY id"},
      {"external_attempts",
       "SELECT ordinal,delivery_id,attempt_id,token,stage,outcome,conditional_protected,evidence_ref,at FROM delivery_attempts ORDER BY ordinal"}
    ]

    Map.new(queries, fn {name, query} -> {name, normalize(S.rows(tx, query, []))} end)
  end

  defp normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize(%Decimal{} = value), do: %{"exact_decimal" => Decimal.to_string(value, :normal)}
  defp normalize(value) when is_integer(value), do: %{"integer" => to_string(value)}
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, normalize(v)} end)
  defp normalize(value), do: value

  defp root_proof(%{
         root_owner: owner,
         root: root,
         root_token: token,
         prefixes: prefixes,
         manifests: manifests
       })
       when is_pid(owner) and is_binary(root) and is_reference(token) and is_list(prefixes) and
              is_map(manifests) do
    if GenServer.call(owner, {:med_ex_root_ownership, root}, 1_000) ==
         {:ok, %{root: root, token: token}}, do: :ok, else: {:error, :root_ownership_unverified}
  catch
    :exit, _ -> {:error, :root_ownership_unverified}
  end

  defp root_proof(_), do: {:error, :root_ownership_unverified}

  defp verify_artifacts!(tx, proof) do
    expected =
      S.rows(
        tx,
        "SELECT fence,receipt,index_digest FROM stream_attempts WHERE receipt IS NOT NULL ORDER BY fence",
        []
      )

    prefixes = Enum.sort_by(proof.prefixes, & &1.fence)
    unless length(prefixes) == length(expected), do: S.abort(tx, :artifact_inventory_incomplete)

    Enum.zip(expected, prefixes)
    |> Enum.each(&verify_prefix!(tx, proof, &1))

    manifests =
      S.rows(
        tx,
        "SELECT acquisition_id,digest,body FROM acquisition_manifests ORDER BY acquisition_id",
        []
      )

    unless map_size(proof.manifests) == length(manifests),
      do: S.abort(tx, :manifest_inventory_incomplete)

    Enum.each(manifests, fn [id, digest, body] ->
      bytes = proof.manifests[id]

      unless is_binary(bytes) and S.hash(bytes) == digest and CanonicalJSON.encode(body) == bytes,
        do: S.abort(tx, :manifest_inventory_conflict)
    end)
  end

  defp verify_prefix!(
         tx,
         proof,
         {[fence, receipt, digest], %MedEx.Storage.RecoveredPrefix{} = prefix}
       ) do
    provenance = prefix.provenance

    unless prefix.fence == fence and Receipt.exact_prefix?(receipt, prefix.receipt) and
             prefix.index_digest == digest and
             provenance[:scope] == :full_journal and provenance[:receipt] == prefix.receipt and
             provenance[:root_owner] == proof.root_owner and
             provenance[:root_token] == proof.root_token and provenance[:root] == proof.root,
           do: S.abort(tx, :artifact_inventory_conflict)
  end

  defp verify_prefix!(tx, _, _), do: S.abort(tx, :artifact_inventory_conflict)

  defp lsn?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9A-F]{1,8}\/[0-9A-F]{1,8}\z/, value)
end
