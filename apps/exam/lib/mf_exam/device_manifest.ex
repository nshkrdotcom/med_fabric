defmodule MedFabric.Exam.DeviceManifest do
  @moduledoc "Verify native bytes before immutable manifest install and database completion."
  alias MedEx.Serialization, as: J
  alias MedEx.Storage.File, as: Storage
  alias MedFabric.Exam.{Barrier, ClockObservations}
  alias MedFabric.Store.DeviceCommands
  alias MedFabric.Store.DeviceSessions, as: S
  alias MedFabric.Store.{MeasurementEvents, Postgres}

  def root(id), do: Path.join([MedFabric.Exam.lab().artifact_dir, "device-v1", S.hash(id)])
  def attempt_dir(id, stream, fence), do: Path.join([root(id), stream, fence])

  def inventory_digest(entries),
    do: J.digest(for row <- entries, do: [row["event"]["event_id"], row["fingerprint"]])

  def finish(bind, final) do
    with {:ok, :ok} <- S.scoped(bind, &request_finish(&1, bind.id, &2, final), :update),
         {:ok, staged} <- stage_scoped(bind, final) do
      finalize_scoped(bind, staged)
    end
  end

  defp request_finish(tx, id, session, final) do
    unless valid_finish?(session.profile, final), do: S.abort(tx, :invalid_finish)

    case S.rows(tx, "SELECT final_inventory FROM device_sessions WHERE id=$1", [id]) do
      [[nil]] ->
        S.rows(
          tx,
          "UPDATE device_sessions SET phase='finalizing',final_inventory=$2 WHERE id=$1",
          [id, final]
        )

      [[^final]] ->
        :ok

      _ ->
        S.abort(tx, :finish_conflict)
    end

    :ok
  end

  defp valid_finish?("plx_spot_check", final), do: valid_inventory?(final)
  defp valid_finish?("paired_exam", final), do: final == %{}
  defp valid_finish?(_, _), do: true

  defp valid_inventory?(%{"count" => n, "digest" => d}) when is_binary(n) and is_binary(d),
    do:
      Regex.match?(~r/\A(0|[1-9][0-9]{0,4})\z/, n) and String.to_integer(n) <= 10_000 and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, d)

  defp valid_inventory?(_), do: false

  defp stage_scoped(bind, final) do
    with {:ok, loaded} <- S.scoped(bind, &load_stage_inputs(&1, bind.id, &2, final), :update) do
      prepare_loaded(bind.id, loaded, :installed_or_recover, &commit_scoped(bind, &1))
    end
  end

  defp commit_scoped(bind, built) do
    S.scoped(bind, fn tx, _ -> commit_staged(tx, bind.id, built) end, :update)
  end

  defp prepare_loaded(_id, {:staged, digest}, _mode, _commit), do: {:ok, {:existing, digest}}

  defp prepare_loaded(id, {:build, inputs}, mode, commit) do
    with {:ok, built} <- prepare_staged_manifest(id, inputs, mode), do: commit.(built)
  end

  defp load_stage_inputs(tx, id, s, final) do
    case S.rows(tx, "SELECT digest FROM device_manifest_staging WHERE acquisition_id=$1", [id]) do
      [[digest]] ->
        {:staged, digest}

      [] ->
        inventory = MeasurementEvents.inventory(tx, id)

        if s.profile == "plx_spot_check" and not inventory_matches?(inventory, final),
          do: S.abort(tx, :inventory_pending)

        attempts = latest_attempts(tx, id, s.descriptors)

        :ok = DeviceCommands.close_pending(tx, id)
        facts = S.facts(tx, id)

        [[gateway, repeat_of]] =
          S.rows(tx, "SELECT device_id,repeat_of FROM device_sessions WHERE id=$1", [id])

        obs_rows =
          S.rows(
            tx,
            "SELECT a.stream,a.fence,o.sequence,o.raw_digest,o.received_at FROM device_transport_observations o JOIN stream_attempts a USING(fence) WHERE a.acquisition_id=$1 ORDER BY a.stream,a.generation,o.sequence,o.raw_digest",
            [id]
          )

        {:build,
         %{
           session: s,
           inventory: inventory,
           facts: facts,
           attempts: attempts,
           gateway: gateway,
           repeat_of: repeat_of,
           obs_rows: obs_rows
         }}
    end
  end

  defp latest_attempts(tx, id, descriptors) do
    Map.new(descriptors, fn {name, descriptor} ->
      case S.rows(
             tx,
             "SELECT fence,index_digest,sealed_index,receipt FROM stream_attempts WHERE acquisition_id=$1 AND stream=$2 ORDER BY generation DESC LIMIT 1",
             [id, name]
           ) do
        [attempt] -> {name, {descriptor, attempt}}
        [] -> S.abort(tx, :missing_stream)
      end
    end)
  end

  defp prepare_staged_manifest(id, inputs, verify_mode) do
    %{
      session: s,
      inventory: inventory,
      facts: facts,
      attempts: attempts,
      gateway: gateway,
      repeat_of: repeat_of,
      obs_rows: obs_rows
    } = inputs

    with {:ok, streams, updates} <- verify_stage_streams(id, attempts, facts, verify_mode) do
      defects =
        for {name, stream} <- Enum.sort(streams),
            code <- defects(stream),
            do: %{"stream" => name, "code" => code}

      defects =
        defects ++
          for f <- facts,
              f["type"] in ["duplicate_conflict", "quarantine"],
              do: %{"stream" => f["body"]["stream"], "code" => f["type"]}

      reason =
        if s.profile == "plx_spot_check" and inventory == [],
          do: [%{"code" => "empty_inventory"}],
          else: []

      receipts =
        for [name, fence, seq, digest, at] <- obs_rows,
            do: [name, fence, to_string(seq), digest, DateTime.to_iso8601(at)]

      summary = %{
        "sha256" => J.digest(receipts),
        "count" => to_string(length(receipts)),
        "basis" => "server_transport_observation"
      }

      manifest = %{
        "gateway" => gateway,
        "repeat_of" => repeat_of,
        "transport_inventory" => summary,
        "schema" => "medfabric.device-manifest.v1",
        "simulated" => true,
        "acquisition" => id,
        "encounter" => s.encounter,
        "profile" => s.profile,
        "site" => s.site,
        "boot" => s.boot,
        "streams" => streams,
        "facts" => facts,
        "inventory" => inventory,
        "defects" => defects ++ reason
      }

      bytes = MedEx.CanonicalJSON.encode(manifest)
      digest = S.hash(bytes)

      versions =
        Map.new(attempts, fn {name, {_, [fence, index_digest, _, receipt]}} ->
          {name, {fence, index_digest, receipt}}
        end)

      {:ok, %{digest: digest, bytes: bytes, updates: updates, versions: versions, facts: facts}}
    end
  end

  defp verify_stage_streams(id, attempts, facts, verify_mode) do
    Enum.reduce_while(attempts, {:ok, %{}, []}, fn {name, {descriptor, attempt}},
                                                   {:ok, streams, updates} ->
      {:ok, spec} = J.stream_spec(descriptor)

      case verify_stage_attempt(id, name, spec, attempt, verify_mode) do
        {:ok, actual, index_map, update} ->
          staged = %{
            "digest" => actual,
            "index" => index_map,
            "clock" => ClockObservations.freeze(name, spec, facts)
          }

          {:cont, put_staged_stream(streams, updates, name, staged, update)}

        :error ->
          {:halt, {:error, :unverified_stream}}
      end
    end)
  end

  defp put_staged_stream(streams, updates, name, staged, update) do
    updates = if update, do: [update | updates], else: updates
    {:ok, Map.put(streams, name, staged), updates}
  end

  defp verify_stage_attempt(
         id,
         name,
         _spec,
         [fence, digest, sealed_index, _known],
         :installed_or_recover
       )
       when is_binary(digest) and is_map(sealed_index) do
    if installed_index_matches?(id, name, fence, sealed_index, digest) do
      {:ok, digest, sealed_index, nil}
    else
      :error
    end
  end

  defp verify_stage_attempt(id, name, spec, [fence, digest, _sealed_index, known], _mode) do
    with {:ok, receipt} <- J.receipt(known),
         {:ok, %{sealed: true, index: index, receipt: recovered_receipt}} <-
           Storage.recover(attempt_dir(id, name, fence),
             stream: spec,
             fence: fence,
             known_receipt: receipt
           ),
         actual = J.digest(index),
         true <- is_nil(digest) or digest == actual do
      index_map = J.to_map(index)
      {:ok, actual, index_map, {fence, actual, index_map, J.to_map(recovered_receipt)}}
    else
      _ -> :error
    end
  end

  defp commit_staged(tx, id, built) do
    case S.rows(tx, "SELECT digest FROM device_manifest_staging WHERE acquisition_id=$1", [id]) do
      [[existing]] ->
        {:existing, existing}

      [] ->
        # The build ran outside this lock. Refuse to stage a superseded snapshot.
        current =
          S.rows(
            tx,
            "SELECT DISTINCT ON (stream) stream,fence,index_digest,receipt FROM stream_attempts WHERE acquisition_id=$1 ORDER BY stream,generation DESC",
            [id]
          )
          |> Map.new(fn [name, fence, index_digest, receipt] ->
            {name, {fence, index_digest, receipt}}
          end)

        unless Map.take(current, Map.keys(built.versions)) == built.versions and
                 S.facts(tx, id) == built.facts do
          S.abort(tx, :stage_changed)
        end

        for {fence, actual, index_map, receipt_map} <- built.updates do
          S.rows(
            tx,
            "UPDATE stream_attempts SET index_digest=$2,sealed_index=$3,receipt=$4 WHERE fence=$1",
            [fence, actual, index_map, receipt_map]
          )
        end

        S.rows(
          tx,
          "INSERT INTO device_manifest_staging(acquisition_id,digest,bytes) VALUES($1,$2,$3)",
          [id, built.digest, built.bytes]
        )

        {:fresh, built.digest}
    end
  end

  defp installed_index_matches?(id, name, fence, index_map, expected_digest)
       when is_binary(fence) and is_map(index_map) and is_binary(expected_digest) do
    bytes = MedEx.CanonicalJSON.encode(index_map)
    hash = S.hash(bytes)

    hash == expected_digest and
      File.read(Path.join(attempt_dir(id, name, fence), hash <> ".index.mej1")) == {:ok, bytes}
  rescue
    _ -> false
  end

  defp installed_index_matches?(_, _, _, _, _), do: false

  defp finalize_scoped(bind, staged) do
    with {:ok, {digest, body, promoted?}} <-
           S.scoped(bind, fn tx, _ -> staged_manifest(tx, bind.id) end),
         true <- S.hash(body) == digest,
         manifest = JSON.decode!(body),
         # Only this invocation can reuse its fresh verification for promotion.
         mode = if(promoted? or staged == {:fresh, digest}, do: :installed, else: :full),
         :ok <- verify_manifest_streams(bind.id, manifest, mode),
         :ok <- ensure_manifest_file(bind.id, body) do
      S.scoped(bind, &promote_manifest(&1, bind.id, &2, digest, manifest), :update)
    else
      false -> {:error, :manifest_conflict}
      error -> error
    end
  end

  defp staged_manifest(tx, id) do
    [[digest, body, promoted?]] =
      S.rows(
        tx,
        """
        SELECT s.digest,s.bytes,EXISTS(
          SELECT 1 FROM device_manifests m WHERE m.acquisition_id=s.acquisition_id AND m.digest=s.digest
        ) FROM device_manifest_staging s WHERE s.acquisition_id=$1
        """,
        [id]
      )

    {digest, body, promoted?}
  end

  defp ensure_manifest_file(id, body) do
    file = Path.join(root(id), "manifest.mej1")

    case File.read(file) do
      {:ok, ^body} -> sync_manifest_directory(Path.dirname(file))
      {:error, :enoent} -> install(file, body)
      _ -> {:error, :manifest_conflict}
    end
  end

  defp verify_manifest_streams(id, m, :installed) do
    ok? =
      Enum.all?(m["streams"], fn {name, stream} ->
        installed_index_matches?(
          id,
          name,
          stream["index"]["fence"],
          stream["index"],
          stream["digest"]
        )
      end)

    if ok?, do: :ok, else: {:error, :unverified_stream}
  end

  defp verify_manifest_streams(id, m, :full) do
    ok? =
      m["streams"]
      |> Task.async_stream(&valid_review_stream?(id, &1),
        ordered: false,
        timeout: 35_000,
        on_timeout: :kill_task
      )
      |> Enum.all?(fn
        {:ok, true} -> true
        _ -> false
      end)

    if ok?, do: :ok, else: {:error, :unverified_stream}
  end

  defp promote_manifest(tx, id, s, digest, m) do
    case S.rows(tx, "SELECT digest FROM device_manifests WHERE acquisition_id=$1", [id]) do
      [[^digest]] ->
        digest

      [] ->
        Barrier.hit("manifest_install")
        state = if m["defects"] == [], do: "ready", else: "ready_partial"

        evidence = %{
          "kind" => s.profile,
          "manifest_digest" => digest,
          "provenance" => %{"kind" => "simulated_device", "simulated" => true}
        }

        if S.rows(
             tx,
             "UPDATE acquisitions SET state=$3,evidence=$4,producer=NULL WHERE encounter_id=$1 AND id=$2 AND state='recording' RETURNING id",
             [s.encounter, id, state, evidence]
           ) == [], do: S.abort(tx, :completion_conflict)

        S.rows(tx, "INSERT INTO device_manifests VALUES($1,$2,$3,now())", [id, digest, m])

        S.rows(tx, "UPDATE device_sessions SET phase='sealed',manifest_digest=$2 WHERE id=$1", [
          id,
          digest
        ])

        if :ets.whereis(:mf_live_ecg) != :undefined, do: :ets.delete(:mf_live_ecg, id)
        Barrier.hit("db_completion")
        digest
    end
  end

  defp inventory_matches?(inventory, final) do
    to_string(length(inventory)) == final["count"] and
      inventory_digest(inventory) == final["digest"] and
      Enum.all?(Enum.with_index(inventory), fn {row, sequence} ->
        row["event"]["gateway_sequence"] == to_string(sequence)
      end)
  end

  defp sealed_index?(id, name, stream, spec) do
    fence = stream["index"]["fence"]
    expected = stream["digest"]

    case Storage.recover(attempt_dir(id, name, fence), stream: spec, fence: fence) do
      {:ok, %{sealed: true, index_digest: ^expected}} -> true
      _ -> false
    end
  end

  def verify_review(enc, id, actor, digest) do
    case S.rows(
           Postgres,
           "SELECT m.digest,m.body FROM device_manifests m JOIN device_sessions s ON s.id=m.acquisition_id JOIN encounters e ON e.id=s.encounter_id WHERE s.id=$1 AND e.id=$2 AND e.clinician_actor=$3 AND e.closed_at IS NULL",
           [id, enc, actor]
         ) do
      [[^digest, m]] ->
        with {:ok, bytes} <- File.read(Path.join(root(id), "manifest.mej1")),
             true <- S.hash(bytes) == digest and MedEx.CanonicalJSON.encode(m) == bytes,
             :ok <- verify_manifest_streams(id, m, :full) do
          :ok
        else
          _ -> {:error, :unverified_manifest}
        end

      _ ->
        {:error, :review_changed}
    end
  end

  defp valid_review_stream?(id, {name, stream}) do
    case J.stream_spec(stream["index"]["stream"]) do
      {:ok, spec} -> sealed_index?(id, name, stream, spec)
      _ -> false
    end
  end

  defp defects(s) do
    index = s["index"]

    if(index["terminal"] == "finished", do: [], else: ["interrupted"]) ++
      if(s["clock"]["state"] == "bounded", do: [], else: ["clock_unavailable"]) ++
      Enum.map(index["spans"], & &1["code"])
  end

  def recover do
    # File paths are owned exclusively by one Exam service. On restart its writer
    # processes are dead. Reconcile only frozen, previously requested finishes.
    for [id, enc, boot, p, site, descriptors, final] <-
          S.rows(
            Postgres,
            "SELECT id,encounter_id,boot,profile,site,descriptors,final_inventory FROM device_sessions WHERE phase='finalizing'",
            []
          ) do
      recover_finish(
        id,
        %{encounter: enc, boot: boot, profile: p, site: site, descriptors: descriptors},
        final
      )
    end

    :ok
  end

  defp recover_finish(id, session, final) do
    result =
      with {:ok, staged} <- prepare_recovery(id, session, final),
           {:ok, {digest, body, _}} <-
             Postgrex.transaction(Postgres, &staged_manifest(&1, id)),
           true <- S.hash(body) == digest,
           manifest = JSON.decode!(body),
           mode = if(staged == {:fresh, digest}, do: :installed, else: :full),
           :ok <- verify_manifest_streams(id, manifest, mode),
           :ok <- ensure_manifest_file(id, body) do
        Postgrex.transaction(Postgres, fn tx ->
          require_finalizing!(tx, id)
          promote_manifest(tx, id, session, digest, manifest)
        end)
      else
        false -> {:error, :manifest_conflict}
        error -> error
      end

    recovery_result(id, result)
  end

  defp prepare_recovery(id, session, final) do
    loaded =
      Postgrex.transaction(Postgres, fn tx ->
        require_finalizing!(tx, id)
        load_stage_inputs(tx, id, session, final)
      end)

    with {:ok, loaded} <- loaded do
      prepare_loaded(id, loaded, :full, &commit_recovery(id, &1))
    end
  end

  defp commit_recovery(id, built) do
    Postgrex.transaction(Postgres, fn tx ->
      require_finalizing!(tx, id)
      commit_staged(tx, id, built)
    end)
  end

  defp require_finalizing!(tx, id) do
    unless S.rows(tx, "SELECT phase FROM device_sessions WHERE id=$1 FOR UPDATE", [id]) ==
             [["finalizing"]],
           do: S.abort(tx, :inactive)
  end

  defp recovery_result(_, {:ok, _}), do: :ok
  defp recovery_result(_, {:error, :inventory_pending}), do: :awaiting_upload

  defp recovery_result(id, {:error, reason}) do
    require Logger
    Logger.error("Device manifest recovery blocked (#{S.hash(id)}): #{inspect(reason, limit: 5)}")
    :blocked
  end

  defp install(file, bytes) do
    dir = Path.dirname(file)
    File.mkdir_p!(dir)
    tmp = file <> "." <> S.nonce()

    try do
      File.open!(tmp, [:write, :binary, :exclusive], fn io ->
        :ok = IO.binwrite(io, bytes)
        :ok = :file.sync(io)
      end)

      case File.ln(tmp, file) do
        :ok ->
          sync_manifest_directory(dir)

        {:error, :eexist} ->
          if File.read(file) == {:ok, bytes},
            do: sync_manifest_directory(dir),
            else: {:error, :manifest_conflict}

        error ->
          error
      end
    after
      File.rm(tmp)
    end
  end

  defp sync_manifest_directory(dir) do
    with {:ok, fd} <- :file.open(String.to_charlist(dir), [:raw, :read, :directory]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end
end
