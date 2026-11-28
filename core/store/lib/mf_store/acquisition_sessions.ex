defmodule MedFabric.Store.AcquisitionSessions do
  @moduledoc "Sole SQL owner for source-neutral admission, attempt reservations, durable facts and finalization. Every operation takes an explicit database or transaction."
  alias MedEx.{Receipt, Serialization}
  alias MedFabric.Store.{DeviceCommands, MeasurementEvents}

  @profiles ["paired_exam", "plx_spot_check", "browser_microphone"]
  @max_attempts 32
  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def nonce, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  @doc false
  def rows(tx, sql, args), do: Postgrex.query!(tx, sql, args).rows
  @doc false
  @spec abort(DBConnection.t(), term()) :: no_return()
  def abort(tx, reason), do: Postgrex.rollback(tx, reason)

  def authorize_encounter!(tx, id, actor, role, access, mode \\ :update) do
    lock = if mode == :share, do: "FOR SHARE", else: "FOR UPDATE"

    case rows(
           tx,
           "SELECT patient_actor,clinician_actor,closed_at FROM encounters WHERE id=$1 " <> lock,
           [id]
         ) do
      [[patient, clinician, closed]] ->
        expected = if role == :patient, do: patient, else: clinician

        unless actor == expected and (access == :read or is_nil(closed)),
          do: abort(tx, :unauthorized)

      _ ->
        abort(tx, :unauthorized)
    end

    :ok
  end

  def authorize_browser!(tx, id, enc, actor, role, access, mode \\ :update) do
    authorize_encounter!(tx, enc, actor, role, access, mode)

    unless rows(
             tx,
             "SELECT id FROM browser_sessions WHERE id=$1 AND encounter_id=$2 AND actor=$3 AND role=$4 AND NOT revoked AND expires_at>clock_timestamp() FOR SHARE",
             [id, enc, actor, to_string(role)]
           ) == [[id]], do: abort(tx, :session_expired)

    :ok
  end

  def create_browser(db, enc, actor, session, page, request_id) do
    if Enum.all?([page, request_id], &identifier?/1) do
      Postgrex.transaction(db, &create_browser_locked(&1, enc, actor, session, page, request_id))
    else
      {:error, :invalid_creation}
    end
  end

  defp create_browser_locked(tx, enc, actor, session, page, request_id) do
    authorize_browser!(tx, session, enc, actor, :patient, :mutate)
    writable!(tx)

    case rows(
           tx,
           "SELECT page,session_id,acquisition_id,binding_secret FROM browser_creations WHERE encounter_id=$1 AND actor=$2 AND request_id=$3",
           [enc, actor, request_id]
         ) do
      [[^page, ^session, id, secret]] ->
        %{acquisition: id, creation: secret, page: page}

      [] ->
        id = nonce()
        secret = nonce()
        insert_acquisition!(tx, id, enc, "browser", actor, "browser_microphone", nil)

        rows(
          tx,
          "INSERT INTO browser_creations(encounter_id,actor,request_id,page,session_id,acquisition_id,binding_hash,binding_secret) VALUES($1,$2,$3,$4,$5,$6,$7,$8)",
          [enc, actor, request_id, page, session, id, hash(secret), secret]
        )

        %{acquisition: id, creation: secret, page: page}

      _ ->
        abort(tx, :creation_conflict)
    end
  end

  def admit(db, principal, hello) when is_map(principal) and is_map(hello) do
    with 2 <- hello["api_revision"],
         true <- Enum.all?(~w(acquisition encounter boot), &identifier?(hello[&1])),
         true <- hello["profile"] in @profiles,
         :ok <- descriptors(principal, hello) do
      Postgrex.transaction(db, fn tx ->
        admit_locked(tx, principal, hello)
      end)
    else
      _ -> {:error, :invalid_hello}
    end
  end

  def admit(_, _, _), do: {:error, :invalid_hello}

  defp admit_locked(tx, principal, hello) do
    enc = hello["encounter"]
    id = hello["acquisition"]
    profile = hello["profile"]
    actor = principal.id
    writable!(tx)
    site = admission_authority!(tx, principal, hello)

    admit_acquisition!(tx, principal, enc, id, profile, actor)

    existing =
      rows(
        tx,
        "SELECT boot,descriptors,generation,authority_state,maximum_at>clock_timestamp() FROM acquisition_sessions WHERE id=$1 FOR UPDATE",
        [id]
      )

    lease = nonce()

    admit_session!(tx, existing, principal, hello, {id, enc, profile, actor}, site, lease)

    [[generation, remaining]] =
      rows(
        tx,
        "UPDATE acquisition_sessions SET generation=generation+1,lease_hash=$2,connection_state='active',expires_at=LEAST(maximum_at,clock_timestamp()+interval '30 seconds') WHERE id=$1 RETURNING generation,GREATEST(0,LEAST(30000,FLOOR(EXTRACT(EPOCH FROM (expires_at-clock_timestamp()))*1000)))::integer",
        [id, hash(lease)]
      )

    unless remaining > 0, do: abort(tx, :authority_ended)

    rows(tx, "UPDATE acquisitions SET state='capturing' WHERE id=$1 AND state='reserved'", [
      id
    ])

    %{
      id: id,
      encounter: enc,
      source_kind: principal.kind,
      principal: actor,
      browser_session: Map.get(principal, :session),
      profile: profile,
      boot: hello["boot"],
      generation: generation,
      lease: lease,
      connection: nonce(),
      authority_ms: remaining,
      phase: admission_phase(tx, id)
    }
  end

  defp admit_acquisition!(tx, principal, enc, id, profile, actor) do
    case rows(
           tx,
           "SELECT encounter_id,source_kind,principal,profile,state FROM acquisitions WHERE id=$1 FOR UPDATE",
           [id]
         ) do
      [] when principal.kind == :device ->
        insert_acquisition!(tx, id, enc, "device", actor, profile, nil)

      [[^enc, kind, ^actor, ^profile, state]]
      when state in ["reserved", "capturing", "finalizing", "staged", "promoted"] ->
        unless kind == to_string(principal.kind), do: abort(tx, :principal_changed)

      _ ->
        abort(tx, :resume_conflict)
    end
  end

  defp admit_session!(tx, existing, principal, hello, {id, enc, profile, actor}, site, lease) do
    case existing do
      [] ->
        {device, patient, browser} =
          if principal.kind == :device,
            do: {actor, nil, nil},
            else: {nil, actor, principal.session}

        rows(
          tx,
          "INSERT INTO acquisition_sessions(id,encounter_id,source_kind,principal,profile,device_id,patient_actor,browser_session,boot,site,descriptors,lease_hash,expires_at,maximum_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,clock_timestamp()+interval '30 seconds',clock_timestamp()+interval '30 minutes')",
          [
            id,
            enc,
            to_string(principal.kind),
            actor,
            profile,
            device,
            patient,
            browser,
            hello["boot"],
            site,
            hello["descriptors"],
            hash(lease)
          ]
        )

      [[boot, desc, _, "authorized", true]] ->
        unless boot == hello["boot"] and desc == hello["descriptors"],
          do: abort(tx, :immutable_source_changed)

      _ ->
        abort(tx, :authority_ended)
    end
  end

  defp admission_phase(tx, id) do
    case rows(tx, "SELECT state FROM acquisitions WHERE id=$1", [id]) do
      [["promoted"]] -> "sealed"
      [[state]] when state in ["staged", "finalizing"] -> "finalizing"
      _ -> "capturing"
    end
  end

  defp admission_authority!(tx, %{kind: :device, id: actor}, hello) do
    enc = hello["encounter"]

    case rows(tx, "SELECT closed_at FROM encounters WHERE id=$1 FOR UPDATE", [enc]) do
      [[nil]] -> :ok
      _ -> abort(tx, :encounter_closed)
    end

    case rows(
           tx,
           "SELECT g.site FROM device_grants g JOIN device_credentials c USING(device_id) WHERE g.encounter_id=$1 AND g.device_id=$2 AND g.profile=$3 AND NOT g.revoked AND NOT c.revoked AND g.expires_at>clock_timestamp() FOR SHARE OF g,c",
           [enc, actor, hello["profile"]]
         ) do
      [[site]] -> site
      _ -> abort(tx, :grant_denied)
    end
  end

  defp admission_authority!(tx, %{kind: :browser, id: actor, session: session}, hello) do
    authorize_browser!(tx, session, hello["encounter"], actor, :patient, :mutate)

    unless hello["profile"] == "browser_microphone" and is_binary(hello["creation"]),
      do: abort(tx, :invalid_creation)

    unless rows(
             tx,
             "SELECT acquisition_id FROM browser_creations WHERE acquisition_id=$1 AND actor=$2 AND session_id=$3 AND page=$4 AND binding_hash=$5",
             [hello["acquisition"], actor, session, hello["boot"], hash(hello["creation"])]
           ) == [[hello["acquisition"]]], do: abort(tx, :invalid_creation)

    "browser microphone"
  end

  def scoped(db, bind, fun, mode \\ :share) do
    Postgrex.transaction(
      db,
      fn tx ->
        writable!(tx)
        snapshot = snapshot!(tx, bind.id, mode)
        authorize_binding!(tx, bind, snapshot, mode)
        fun.(tx, snapshot)
      end,
      timeout: 40_000
    )
  end

  def settlement(db, id, fun) do
    Postgrex.transaction(
      db,
      fn tx ->
        snapshot = snapshot!(tx, id, :update)
        fun.(tx, snapshot)
      end,
      timeout: 40_000
    )
  end

  def current?(db, bind), do: match?({:ok, true}, scoped(db, bind, fn _, _ -> true end))

  def snapshot!(tx, id, mode) do
    enc =
      case rows(tx, "SELECT encounter_id FROM acquisitions WHERE id=$1", [id]) do
        [[enc]] -> enc
        _ -> abort(tx, :unknown_acquisition)
      end

    {lock, session_lock} =
      case mode do
        :update -> {" FOR UPDATE", " FOR UPDATE"}
        :read -> {"", ""}
        _ -> {" FOR SHARE", " FOR KEY SHARE"}
      end

    [[patient, clinician, closed]] =
      rows(
        tx,
        "SELECT patient_actor,clinician_actor,closed_at FROM encounters WHERE id=$1" <> lock,
        [enc]
      )

    [[state, kind, principal, profile, parent]] =
      rows(
        tx,
        "SELECT state,source_kind,principal,profile,parent_acquisition_id FROM acquisitions WHERE id=$1" <>
          lock,
        [id]
      )

    case rows(
           tx,
           "SELECT boot,site,descriptors,generation,lease_hash,authority_state,connection_state,expires_at,maximum_at,device_id,patient_actor,browser_session,final_inventory,frozen_at,frozen_generation FROM acquisition_sessions WHERE id=$1" <>
             session_lock,
           [id]
         ) do
      [
        [
          boot,
          site,
          descriptors,
          generation,
          lease,
          authority,
          connection,
          expires,
          maximum,
          device,
          browser_actor,
          browser_session,
          final,
          frozen,
          frozen_generation
        ]
      ] ->
        %{
          id: id,
          encounter: enc,
          patient: patient,
          clinician: clinician,
          closed_at: closed,
          state: state,
          source_kind: kind,
          principal: principal,
          profile: profile,
          repeat_of: parent,
          boot: boot,
          site: site,
          descriptors: descriptors,
          generation: generation,
          lease_hash: lease,
          authority: authority,
          connection: connection,
          expires_at: expires,
          maximum_at: maximum,
          device: device,
          browser_actor: browser_actor,
          browser_session: browser_session,
          final_inventory: final,
          frozen_at: frozen,
          frozen_generation: frozen_generation
        }

      _ ->
        abort(tx, :session_missing)
    end
  end

  defp authorize_binding!(tx, bind, s, mode) do
    unless same_binding?(s, bind) and hash(bind.lease) == s.lease_hash and
             authority_ms(tx, s.id) > 0,
           do: abort(tx, :stale_binding)

    authorize_source!(tx, s, mode)
  end

  defp same_binding?(s, bind) do
    s.closed_at == nil and s.authority == "authorized" and s.generation == bind.generation and
      s.principal == bind.principal and s.profile == bind.profile and
      s.source_kind == to_string(bind.source_kind) and
      (s.source_kind != "browser" or s.browser_session == bind.browser_session)
  end

  def authorize_source!(tx, s, mode \\ :share) do
    unless is_nil(s.closed_at) and s.authority == "authorized" and authority_ms(tx, s.id) > 0,
      do: abort(tx, :authority_ended)

    case s.source_kind do
      "device" ->
        unless rows(
                 tx,
                 "SELECT c.device_id FROM device_credentials c JOIN device_grants g USING(device_id) WHERE c.device_id=$1 AND g.encounter_id=$2 AND g.profile=$3 AND NOT c.revoked AND NOT g.revoked AND g.expires_at>clock_timestamp()" <>
                   source_lock(:device, mode),
                 [s.device, s.encounter, s.profile]
               ) == [[s.device]], do: abort(tx, :grant_denied)

      "browser" ->
        unless rows(
                 tx,
                 "SELECT id FROM browser_sessions WHERE id=$1 AND encounter_id=$2 AND actor=$3 AND role='patient' AND NOT revoked AND expires_at>clock_timestamp()" <>
                   source_lock(:browser, mode),
                 [s.browser_session, s.encounter, s.principal]
               ) == [[s.browser_session]], do: abort(tx, :session_expired)
    end
  end

  defp source_lock(_, :read), do: ""
  defp source_lock(:device, _), do: " FOR SHARE OF g,c"
  defp source_lock(:browser, _), do: " FOR SHARE"

  def authority_ms(tx, id) do
    case rows(
           tx,
           "SELECT GREATEST(0,LEAST(30000,FLOOR(EXTRACT(EPOCH FROM (LEAST(expires_at,maximum_at)-clock_timestamp()))*1000)))::integer FROM acquisition_sessions WHERE id=$1",
           [id]
         ) do
      [[remaining]] -> remaining
      _ -> 0
    end
  end

  def heartbeat(db, bind, nonce) do
    if identifier?(nonce) do
      scoped(db, bind, fn tx, s ->
        [[remaining]] =
          rows(
            tx,
            "UPDATE acquisition_sessions SET expires_at=LEAST(maximum_at,clock_timestamp()+interval '30 seconds'),connection_state='active' WHERE id=$1 RETURNING GREATEST(0,LEAST(30000,FLOOR(EXTRACT(EPOCH FROM (expires_at-clock_timestamp()))*1000)))::integer",
            [s.id]
          )

        stop =
          rows(
            tx,
            "SELECT ordinal FROM acquisition_facts WHERE acquisition_id=$1 AND kind='operator_stop' LIMIT 1",
            [s.id]
          ) != []

        %{nonce: nonce, remaining_ms: remaining, stop_requested: stop}
      end)
    else
      {:error, :invalid_nonce}
    end
  end

  def disconnected(db, bind) do
    settlement(db, bind.id, fn tx, s ->
      if s.generation == bind.generation and s.lease_hash == hash(bind.lease),
        do:
          rows(
            tx,
            "UPDATE acquisition_sessions SET connection_state='disconnected' WHERE id=$1",
            [s.id]
          )

      :ok
    end)
  end

  def reserve_attempt(tx, s, stream) do
    unless s.state in ["capturing", "finalizing"] and Map.has_key?(s.descriptors, stream),
      do: abort(tx, :inactive)

    attempts = attempts(tx, s.id, stream)
    if length(attempts) >= @max_attempts, do: abort(tx, :attempt_capacity)

    case Enum.find(attempts, &(&1.generation == s.generation)) do
      nil ->
        fence = nonce()
        number = if stream == "audio", do: 1, else: 2

        rows(
          tx,
          "INSERT INTO stream_attempts(acquisition_id,stream,number,generation,fence) VALUES($1,$2,$3,$4,$5)",
          [s.id, stream, number, s.generation, fence]
        )

        %{
          fence: fence,
          number: number,
          generation: s.generation,
          receipt: nil,
          index: nil,
          digest: nil,
          state: "reserved"
        }

      %{state: state} = attempt when state in ["reserved", "terminal"] ->
        attempt

      _ ->
        abort(tx, :readmission_required)
    end
  end

  @doc "Reserve a fresh journal solely for terminal settlement after raw authority has ended. Frozen evidence identity does not change."
  def reserve_settlement_attempt(tx, s, stream) do
    unless s.authority != "authorized" and s.frozen_at != nil and
             s.state in ["finalizing", "interrupted"] and Map.has_key?(s.descriptors, stream),
           do: abort(tx, :settlement_not_authorized)

    previous = attempts(tx, s.id, stream)
    if length(previous) >= @max_attempts, do: abort(tx, :attempt_capacity)

    if Enum.any?(previous, &(&1.state in ["open", "unknown"])),
      do: abort(tx, :prior_effect_not_quiescent)

    generation =
      if Enum.any?(previous, &(&1.generation == s.generation)) do
        [[generation]] =
          rows(
            tx,
            "UPDATE acquisition_sessions SET generation=generation+1 WHERE id=$1 RETURNING generation",
            [s.id]
          )

        generation
      else
        s.generation
      end

    fence = nonce()
    number = if stream == "audio", do: 1, else: 2

    rows(
      tx,
      "INSERT INTO stream_attempts(acquisition_id,stream,number,generation,fence) VALUES($1,$2,$3,$4,$5)",
      [s.id, stream, number, generation, fence]
    )

    %{
      fence: fence,
      number: number,
      generation: generation,
      receipt: nil,
      index: nil,
      digest: nil,
      state: "reserved"
    }
  end

  def attempts(tx, id, stream) do
    for [f, g, n, state, r, index, digest] <-
          rows(
            tx,
            "SELECT fence,generation,number,attempt_state,receipt,sealed_index,index_digest FROM stream_attempts WHERE acquisition_id=$1 AND stream=$2 ORDER BY generation DESC FOR UPDATE",
            [id, stream]
          ),
        do: %{
          fence: f,
          generation: g,
          number: n,
          state: state,
          receipt: r,
          index: index,
          digest: digest
        }
  end

  def record_receipt(tx, fence, %Receipt{} = receipt, terminal \\ nil) do
    unless Receipt.durable?(receipt), do: abort(tx, :volatile_receipt)

    case rows(tx, "SELECT receipt,attempt_state FROM stream_attempts WHERE fence=$1 FOR UPDATE", [
           fence
         ]) do
      [[known, state]] ->
        verify_known_receipt!(tx, known, receipt)

        unless state == "open" and is_nil(terminal) and known == Receipt.to_map(receipt) do
          persist_receipt!(tx, fence, known, state, receipt, terminal)
        end

        receipt

      _ ->
        abort(tx, :unknown_attempt)
    end
  end

  defp verify_known_receipt!(_tx, known, _receipt) when known in [nil, false], do: :ok

  defp verify_known_receipt!(tx, known, receipt) do
    with {:ok, old} <- Receipt.parse(known), :ok <- Receipt.observe(old, receipt) do
      :ok
    else
      _ -> abort(tx, :receipt_conflict)
    end
  end

  defp persist_receipt!(tx, _fence, known, "terminal", receipt, nil) do
    unless known == Receipt.to_map(receipt), do: abort(tx, :sealed_attempt)
  end

  defp persist_receipt!(tx, fence, _known, _state, receipt, terminal) do
    case terminal do
      nil ->
        rows(
          tx,
          "UPDATE stream_attempts SET receipt=$2,attempt_state='open' WHERE fence=$1",
          [fence, Receipt.to_map(receipt)]
        )

      index ->
        rows(
          tx,
          "UPDATE stream_attempts SET receipt=$2,attempt_state='terminal',sealed_index=$3,index_digest=$4 WHERE fence=$1",
          [
            fence,
            Receipt.to_map(receipt),
            Serialization.to_map(index),
            Serialization.digest(index)
          ]
        )
    end
  end

  def mark_attempt(tx, fence, state) when state in ["quiescent", "unknown"],
    do:
      rows(
        tx,
        "UPDATE stream_attempts SET attempt_state=$2 WHERE fence=$1 AND attempt_state<>'terminal'",
        [fence, state]
      )

  def transport(tx, fence, sequence, raw) do
    digest = hash(raw)

    case rows(
           tx,
           "SELECT raw_digest FROM transport_observations WHERE fence=$1 AND sequence=$2",
           [fence, sequence]
         ) do
      [[^digest]] ->
        :ok

      [] ->
        rows(
          tx,
          "INSERT INTO transport_observations(fence,sequence,raw_digest) VALUES($1,$2,$3)",
          [fence, sequence, digest]
        )

        :ok

      _ ->
        abort(tx, :transport_conflict)
    end
  end

  def fact(tx, id, kind, body) do
    if rows(tx, "SELECT count(*) FROM acquisition_facts WHERE acquisition_id=$1", [id]) >= [
         [100_000]
       ],
       do: abort(tx, :fact_capacity)

    rows(tx, "INSERT INTO acquisition_facts(acquisition_id,kind,fact) VALUES($1,$2,$3)", [
      id,
      kind,
      body
    ])

    :ok
  end

  def record_fact(db, bind, kind, body),
    do:
      scoped(db, bind, fn tx, s ->
        unless s.state == "capturing", do: abort(tx, :frozen_evidence)
        fact(tx, s.id, kind, body)
      end)

  def facts(tx, id),
    do:
      for(
        [k, b, at] <-
          rows(
            tx,
            "SELECT kind,fact,recorded_at FROM acquisition_facts WHERE acquisition_id=$1 ORDER BY ordinal",
            [id]
          ),
        do: %{"type" => k, "body" => b, "received_at" => DateTime.to_iso8601(at)}
      )

  def stop(db, enc, id, actor) do
    Postgrex.transaction(db, fn tx ->
      authorize_encounter!(tx, enc, actor, :clinician, :mutate)
      s = snapshot!(tx, id, :update)
      unless s.encounter == enc and s.state == "capturing", do: abort(tx, :inactive)
      fact(tx, id, "operator_stop", %{"actor" => actor})
    end)
  end

  def completed(db, bind, final),
    do:
      scoped(db, bind, fn tx, s ->
        if s.state == "promoted" do
          completed_manifest!(tx, s, final)
        else
          :pending
        end
      end)

  defp completed_manifest!(tx, s, final) do
    unless s.final_inventory == final, do: abort(tx, :finish_conflict)

    case rows(tx, "SELECT digest,body FROM acquisition_manifests WHERE acquisition_id=$1", [
           s.id
         ]) do
      [[digest, body]] -> {digest, body}
      _ -> abort(tx, :unverified_manifest)
    end
  end

  def freeze(db, bind, final, clock),
    do:
      scoped(
        db,
        bind,
        fn tx, s ->
          unless s.state in ["capturing", "finalizing", "staged", "promoted"],
            do: abort(tx, :inactive)

          unless is_nil(s.final_inventory) or s.final_inventory == final,
            do: abort(tx, :finish_conflict)

          if is_nil(s.final_inventory) do
            fact(tx, s.id, "clock_freeze", clock)

            rows(
              tx,
              "UPDATE acquisition_sessions SET final_inventory=$2,frozen_at=clock_timestamp(),frozen_generation=generation WHERE id=$1",
              [s.id, final]
            )

            rows(tx, "UPDATE acquisitions SET state='finalizing' WHERE id=$1", [s.id])
            DeviceCommands.close_pending(tx, s.id)
          end

          :ok
        end,
        :update
      )

  def frozen_inputs(tx, s) do
    inventory = MeasurementEvents.inventory(tx, s.id)

    streams =
      Map.new(Enum.sort(s.descriptors), fn {name, descriptor} ->
        {name, %{descriptor: descriptor, attempts: attempts(tx, s.id, name)}}
      end)

    transport =
      for [stream, fence, q, digest, at] <-
            rows(
              tx,
              "SELECT a.stream,a.fence,o.sequence,o.raw_digest,o.received_at FROM transport_observations o JOIN stream_attempts a USING(fence) WHERE a.acquisition_id=$1 ORDER BY a.stream,a.generation,o.sequence",
              [s.id]
            ),
          do: [stream, fence, to_string(q), digest, DateTime.to_iso8601(at)]

    %{
      session: s,
      streams: streams,
      inventory: inventory,
      facts: facts(tx, s.id),
      transport: transport
    }
  end

  def snapshot_digest(inputs) do
    stable =
      update_in(
        inputs.session,
        &Map.take(&1, [
          :id,
          :encounter,
          :source_kind,
          :principal,
          :profile,
          :boot,
          :site,
          :descriptors,
          :frozen_generation,
          :final_inventory,
          :frozen_at,
          :repeat_of
        ])
      )

    bytes = :erlang.term_to_binary(stable, [:deterministic])
    hash(bytes)
  end

  def stage(tx, s, expected, bytes, digest) do
    unless s.state in ["finalizing", "staged", "promoted"] and
             snapshot_digest(frozen_inputs(tx, s)) == expected,
           do: abort(tx, :snapshot_changed)

    case rows(
           tx,
           "SELECT digest,bytes FROM acquisition_manifest_staging WHERE acquisition_id=$1",
           [s.id]
         ) do
      [[^digest, ^bytes]] ->
        :ok

      [] ->
        rows(
          tx,
          "INSERT INTO acquisition_manifest_staging(acquisition_id,digest,bytes,snapshot_digest) VALUES($1,$2,$3,$4)",
          [s.id, digest, bytes, expected]
        )

        rows(tx, "UPDATE acquisitions SET state='staged' WHERE id=$1", [s.id])
        :ok

      _ ->
        abort(tx, :manifest_conflict)
    end
  end

  def staged(tx, id) do
    case rows(
           tx,
           "SELECT digest,bytes,snapshot_digest FROM acquisition_manifest_staging WHERE acquisition_id=$1",
           [id]
         ) do
      [[digest, bytes, snapshot]] -> {:ok, %{digest: digest, bytes: bytes, snapshot: snapshot}}
      [] -> {:error, :not_staged}
    end
  end

  def promote(tx, s, digest, body) do
    case rows(tx, "SELECT digest FROM acquisition_manifests WHERE acquisition_id=$1", [s.id]) do
      [[^digest]] ->
        digest

      [] ->
        unless s.state == "staged", do: abort(tx, :not_staged)

        rows(
          tx,
          "INSERT INTO acquisition_manifests(acquisition_id,encounter_id,digest,body) VALUES($1,$2,$3,$4)",
          [s.id, s.encounter, digest, body]
        )

        rows(tx, "UPDATE acquisitions SET state='promoted' WHERE id=$1", [s.id])
        digest

      _ ->
        abort(tx, :manifest_conflict)
    end
  end

  def manifest(db, enc, id, actor, digest) do
    Postgrex.transaction(db, fn tx ->
      authorize_encounter!(tx, enc, actor, :clinician, :read, :share)

      case rows(
             tx,
             "SELECT body FROM acquisition_manifests WHERE encounter_id=$1 AND acquisition_id=$2 AND digest=$3",
             [enc, id, digest]
           ) do
        [[body]] -> body
        _ -> abort(tx, :unverified_manifest)
      end
    end)
  end

  def list(db, enc, actor) do
    Postgrex.transaction(db, fn tx ->
      authorize_encounter!(tx, enc, actor, :clinician, :read, :share)

      for [id, profile, principal, site, state, body, digest, choice, descriptors, generation] <-
            rows(
              tx,
              "SELECT a.id,a.profile,a.principal,s.site,a.state,m.body,m.digest,r.choice,s.descriptors,s.generation FROM acquisitions a JOIN acquisition_sessions s USING(id) LEFT JOIN acquisition_manifests m ON m.acquisition_id=a.id LEFT JOIN reviews r ON r.acquisition_id=a.id WHERE a.encounter_id=$1 ORDER BY a.created_at DESC LIMIT 32",
              [enc]
            ),
          do: %{
            id: id,
            profile: profile,
            device: principal,
            site: site,
            phase: state,
            manifest: body,
            digest: digest,
            choice: choice,
            descriptors: descriptors,
            generation: generation,
            metrics:
              rows(
                tx,
                "SELECT o.id,o.body->>'kind',d.status FROM observations o JOIN reviews r ON r.id=o.decision_id LEFT JOIN outbox_deliveries d ON d.observation_id=o.id WHERE r.acquisition_id=$1",
                [id]
              ),
            facts: facts(tx, id)
          }
    end)
  end

  def expiring(db),
    do:
      for(
        [id] <-
          rows(
            db,
            "SELECT s.id FROM acquisition_sessions s JOIN acquisitions a USING(id) JOIN encounters e ON e.id=s.encounter_id WHERE a.state IN ('capturing','finalizing','staged','interrupted') AND (s.authority_state<>'authorized' OR s.expires_at<=clock_timestamp() OR s.maximum_at<=clock_timestamp() OR e.closed_at IS NOT NULL OR (s.device_id IS NOT NULL AND EXISTS(SELECT 1 FROM device_credentials c JOIN device_grants g USING(device_id) WHERE c.device_id=s.device_id AND g.encounter_id=s.encounter_id AND g.profile=s.profile AND (c.revoked OR g.revoked OR g.expires_at<=clock_timestamp()))) OR (s.browser_session IS NOT NULL AND EXISTS(SELECT 1 FROM browser_sessions b WHERE b.id=s.browser_session AND (b.revoked OR b.expires_at<=clock_timestamp())))) LIMIT 64",
            []
          ),
        do: id
      )

  def expire_unadmitted(db) do
    ids =
      rows(
        db,
        "SELECT a.id,a.encounter_id FROM acquisitions a JOIN encounters e ON e.id=a.encounter_id WHERE a.state='reserved' AND NOT EXISTS(SELECT 1 FROM acquisition_sessions s WHERE s.id=a.id) AND (a.created_at<clock_timestamp()-interval '30 seconds' OR e.closed_at IS NOT NULL) ORDER BY a.encounter_id,a.id LIMIT 64",
        []
      )

    Enum.each(ids, fn [id, enc] ->
      Postgrex.transaction(db, fn tx ->
        rows(tx, "SELECT id FROM encounters WHERE id=$1 FOR UPDATE", [enc])

        rows(
          tx,
          "UPDATE acquisitions SET state='interrupted' WHERE id=$1 AND state='reserved' AND NOT EXISTS(SELECT 1 FROM acquisition_sessions WHERE id=$1)",
          [id]
        )
      end)
    end)

    :ok
  end

  def expire(db, id) do
    settlement(db, id, fn tx, s ->
      if id in expiring(tx) do
        rows(
          tx,
          "UPDATE acquisition_sessions SET authority_state='expired',generation=generation+1,connection_state='disconnected' WHERE id=$1 AND authority_state='authorized'",
          [id]
        )

        {:expire, Map.keys(s.descriptors)}
      else
        :current
      end
    end)
  end

  def finish_expiry(db, id, clock),
    do:
      settlement(db, id, fn tx, s ->
        unless s.authority != "authorized", do: abort(tx, :still_authorized)

        unless s.frozen_at do
          final = expiry_inventory(tx, s, id)

          rows(
            tx,
            "UPDATE acquisition_sessions SET final_inventory=$2,frozen_at=clock_timestamp(),frozen_generation=generation WHERE id=$1",
            [id, final]
          )

          fact(tx, id, "clock_freeze", clock)

          fact(tx, id, "interrupted", %{
            "reason" => "authority_ended",
            "trailing_loss" => "unknown"
          })
        end

        rows(
          tx,
          "UPDATE acquisitions SET state='finalizing' WHERE id=$1 AND state IN ('capturing','interrupted')",
          [id]
        )

        DeviceCommands.close_pending(tx, id)
        :ok
      end)

  defp expiry_inventory(tx, s, id) do
    if s.profile == "plx_spot_check" do
      inventory = MeasurementEvents.inventory(tx, id)

      %{
        "count" => to_string(length(inventory)),
        "digest" =>
          Serialization.digest(
            for row <- inventory, do: [row["event"]["event_id"], row["fingerprint"]]
          )
      }
    else
      %{}
    end
  end

  def settlement_pending(db, id) do
    settlement(db, id, fn tx, s ->
      if s.state in ["finalizing", "interrupted"] do
        mark_settlement_pending!(tx, id)
      end

      :ok
    end)
  end

  defp mark_settlement_pending!(tx, id) do
    rows(tx, "UPDATE acquisitions SET state='interrupted' WHERE id=$1", [id])

    rows(
      tx,
      "UPDATE acquisition_sessions SET authority_state='expired',generation=generation+1,connection_state='disconnected' WHERE id=$1 AND authority_state='authorized'",
      [id]
    )

    unless rows(
             tx,
             "SELECT ordinal FROM acquisition_facts WHERE acquisition_id=$1 AND kind='interrupted' LIMIT 1",
             [id]
           ) != [],
           do:
             fact(tx, id, "interrupted", %{
               "reason" => "settlement_pending",
               "trailing_loss" => "unknown"
             })
  end

  def recovery_ids(db),
    do:
      for(
        [id] <-
          rows(
            db,
            "SELECT a.id FROM acquisitions a JOIN acquisition_sessions s USING(id) WHERE a.state IN ('finalizing','staged','interrupted')",
            []
          ),
        do: id
      )

  def preview_authority(db, enc, id, actor, session),
    do:
      Postgrex.transaction(db, fn tx ->
        authorize_browser!(tx, session, enc, actor, :clinician, :mutate, :share)
        s = snapshot!(tx, id, :share)

        unless s.encounter == enc and s.state == "capturing" and s.authority == "authorized" and
                 is_map(s.descriptors["audio"]),
               do: abort(tx, :preview_denied)

        authorize_source!(tx, s)

        [[viewer_remaining]] =
          rows(
            tx,
            "SELECT GREATEST(0,FLOOR(EXTRACT(EPOCH FROM (expires_at-clock_timestamp()))*1000))::integer FROM browser_sessions WHERE id=$1",
            [session]
          )

        remaining = min(25_000, min(authority_ms(tx, id), viewer_remaining))
        unless remaining > 0, do: abort(tx, :preview_denied)
        Map.put(s, :preview_remaining_ms, remaining)
      end)

  def writable!(tx) do
    unless rows(tx, "SELECT recovery_state FROM deployment_identity WHERE singleton", []) == [
             ["current"]
           ],
           do: abort(tx, :restore_reconciliation_required)
  end

  def identifier?(s), do: is_binary(s) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,96}\z/, s)

  defp insert_acquisition!(tx, id, enc, kind, principal, profile, parent) do
    case rows(
           tx,
           "INSERT INTO acquisitions(id,encounter_id,source_kind,principal,profile,state,parent_acquisition_id) VALUES($1,$2,$3,$4,$5,'reserved',$6) ON CONFLICT DO NOTHING RETURNING id",
           [id, enc, kind, principal, profile, parent]
         ) do
      [[^id]] -> :ok
      _ -> abort(tx, :active_profile_busy)
    end
  end

  defp descriptors(principal, hello) do
    expected =
      case hello["profile"] do
        "paired_exam" -> ["audio", "ecg"]
        "browser_microphone" -> ["audio"]
        "plx_spot_check" -> []
      end

    desc = hello["descriptors"]

    valid =
      is_map(desc) and Enum.sort(Map.keys(desc)) == expected and
        Enum.all?(desc, &valid_descriptor?(principal, hello, &1))

    if valid, do: :ok, else: {:error, :invalid_descriptors}
  end

  defp valid_descriptor?(principal, hello, {name, wire}) do
    case Serialization.stream_spec(wire) do
      {:ok, spec} ->
        spec.stream_id == name and spec.acquisition_id == hello["acquisition"] and
          spec.source_ref == principal.id and spec.boot_id == hello["boot"] and
          spec.descriptor_ref == Serialization.descriptor_ref(spec) and
          Serialization.to_map(spec) == wire and modality_matches?(hello["profile"], name, spec)

      _ ->
        false
    end
  end

  defp modality_matches?("browser_microphone", _name, spec),
    do:
      spec.modality == "medex:browser_microphone" and spec.encoding == :s16le and
        spec.sample_rate == {48_000, 1} and length(spec.channels) == 1

  defp modality_matches?(_profile, name, spec),
    do: spec.modality == if(name == "audio", do: "medex:diagnostic_audio", else: "medex:ecg")
end
