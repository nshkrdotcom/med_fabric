defmodule MedFabric.Exam.AcquisitionManifest do
  @moduledoc "Verified source-neutral evidence: frozen snapshot, pure canonical bytes, immutable install, exact promotion."
  alias MedEx.{Receipt, Serialization}
  alias MedEx.Storage.File, as: Storage
  alias MedFabric.Domain.DeviceMeasurement
  alias MedFabric.Exam.{AcquisitionIngress, Barrier, ClockObservations, DeviceRootLock}
  alias MedFabric.Store.AcquisitionSessions, as: S
  alias MedFabric.Store.Postgres

  def root(context, id), do: Path.join([context.artifact_dir, "acquisitions-v2", S.hash(id)])
  def attempt_dir(context, id, name, fence), do: Path.join([root(context, id), name, fence])

  def inventory_digest(entries),
    do:
      Serialization.digest(for row <- entries, do: [row["event"]["event_id"], row["fingerprint"]])

  def finish(context, bind, final) do
    case S.completed(context.db, bind, final) do
      {:ok, {digest, manifest}} ->
        with {:ok, bytes} <- safe_manifest(context, bind.id),
             true <- S.hash(bytes) == digest and MedEx.CanonicalJSON.encode(manifest) == bytes,
             :ok <- verify_full_streams(context, bind.id, manifest) do
          {:ok, digest}
        else
          _ -> {:error, :unverified_manifest}
        end

      {:ok, :pending} ->
        finish_pending(context, bind, final)

      error ->
        error
    end
  end

  defp finish_pending(context, bind, final) do
    with {:ok, :ok} <- S.freeze(context.db, bind, final, ClockObservations.wall_mapping()),
         {:ok, snapshot} <- S.settlement(context.db, bind.id, fn _, s -> s end),
         :ok <- AcquisitionIngress.quiesce(context, bind.id, Map.keys(snapshot.descriptors)) do
      finalize_pending(context, bind.id, Map.keys(snapshot.descriptors))
    end
  end

  def recover(context) do
    Enum.each(S.recovery_ids(context.db), fn id ->
      result = recover_one(context, id)

      case result do
        {:ok, _} -> :ok
        {:error, :inventory_pending} -> :ok
        _ -> S.settlement_pending(context.db, id)
      end
    end)

    :ok
  end

  def settle_interrupted(context, id) do
    with {:ok, s} <- S.settlement(context.db, id, fn _, s -> s end),
         true <- s.authority != "authorized",
         :ok <- AcquisitionIngress.quiesce(context, id, Map.keys(s.descriptors)) do
      gated(context, id, Map.keys(s.descriptors), fn -> finalize_interrupted(context, id) end)
    else
      _ -> {:error, :settlement_pending}
    end
  end

  defp finalize(context, id) do
    with {:ok, settled} <- settle_streams(context, id, false),
         {:ok, inputs} <- S.settlement(context.db, id, fn tx, s -> S.frozen_inputs(tx, s) end),
         {:ok, verified} <- verify_inputs(context, inputs, settled),
         {:ok, built} <- build(verified),
         {:ok, :ok} <-
           S.settlement(context.db, id, fn tx, s ->
             S.stage(tx, s, S.snapshot_digest(inputs), built.bytes, built.digest)
           end),
         :ok <- install(context, id, built.bytes),
         :ok <- Barrier.hit("manifest_install") do
      S.settlement(context.db, id, fn tx, s -> promote_staged(tx, s, id, built) end)
    end
  end

  defp settle_streams(context, id, interrupt?) do
    with {:ok, inputs} <- S.settlement(context.db, id, fn tx, s -> S.frozen_inputs(tx, s) end) do
      Enum.reduce_while(Enum.sort(inputs.streams), {:ok, %{}}, fn {name, stream}, {:ok, acc} ->
        settle_stream(context, id, interrupt?, name, stream, acc)
      end)
    end
  end

  defp settle_stream(context, id, interrupt?, name, stream, acc) do
    {:ok, spec} = Serialization.stream_spec(stream.descriptor)

    result =
      Enum.reduce_while(stream.attempts, {:ok, nil}, fn attempt, {:ok, latest} ->
        settle_attempt(context, id, name, spec, attempt, latest)
      end)

    case result do
      {:ok, %{sealed: true} = prefix} -> {:cont, {:ok, Map.put(acc, name, prefix)}}
      {:ok, prefix} when interrupt? -> settle_successor(context, id, name, spec, prefix, acc)
      _ -> {:halt, {:error, :unresolved_stream}}
    end
  end

  defp settle_successor(context, id, name, spec, prefix, acc) do
    case interrupt_successor(context, id, name, spec, prefix) do
      {:ok, %{sealed: true} = sealed} -> {:cont, {:ok, Map.put(acc, name, sealed)}}
      error -> {:halt, error}
    end
  end

  defp settle_attempt(context, id, name, spec, attempt, latest) do
    dir = attempt_dir(context, id, name, attempt.fence)

    if is_nil(attempt.receipt) and not File.exists?(dir) do
      {:cont, {:ok, latest}}
    else
      settle_journal(context, id, spec, attempt, latest, dir)
    end
  end

  defp settle_journal(context, id, spec, attempt, latest, dir) do
    opts = [stream: spec, fence: attempt.fence, root_owner: context.root_owner]

    opts =
      if attempt.receipt,
        do: Keyword.put(opts, :known_receipt, elem(Receipt.parse(attempt.receipt), 1)),
        else: opts

    with {:ok, prefix} <- Storage.recover(dir, opts),
         {:ok, prefix} <- reconcile_terminal(dir, opts, prefix),
         {:ok, _} <-
           S.settlement(context.db, id, fn tx, _ -> settle_prefix(tx, attempt, prefix) end) do
      {:cont, {:ok, latest || prefix}}
    else
      error -> {:halt, error}
    end
  end

  defp settle_prefix(tx, attempt, prefix) do
    S.record_receipt(tx, attempt.fence, prefix.receipt, if(prefix.sealed, do: prefix.index))
    unless prefix.sealed, do: S.mark_attempt(tx, attempt.fence, "quiescent")
    prefix
  end

  # Journals are immutable once their writer retires. Settlement imports the
  # recovered prefix into a separately committed reservation and admits no raw
  # source frames, including any former writer's volatile backlog.
  defp interrupt_successor(context, id, name, spec, predecessor) do
    with {:ok, attempt} <-
           S.settlement(context.db, id, fn tx, s -> S.reserve_settlement_attempt(tx, s, name) end) do
      dir = attempt_dir(context, id, name, attempt.fence)

      opts = [
        owner: self(),
        fence: attempt.fence,
        stream: spec,
        artifact_dir: dir,
        root_owner: context.root_owner,
        limits: %{checkpoint_ms: :manual}
      ]

      opts = if predecessor, do: Keyword.put(opts, :predecessor, predecessor), else: opts

      result =
        S.settlement(context.db, id, fn tx, s ->
          interrupt_locked(tx, s, opts, attempt, predecessor)
        end)

      with {:ok, %{receipt: receipt}} <- result,
           {:ok, prefix} <-
             Storage.recover(dir,
               stream: spec,
               fence: attempt.fence,
               known_receipt: receipt,
               root_owner: context.root_owner
             ),
           true <- prefix.sealed do
        {:ok, prefix}
      else
        _ -> {:error, :interrupted_seal_unknown}
      end
    end
  end

  defp verify_import(nil, receipt),
    do:
      if(
        Receipt.durable?(receipt) and receipt.durable_sequence == 0 and
          receipt.durable_sample == 0,
        do: :ok,
        else: {:error, :invalid_initial_receipt}
      )

  defp verify_import(prefix, receipt) do
    Receipt.handoff(prefix.receipt, receipt, %{
      authority: :verified_storage,
      authenticated: true,
      quiescent: true,
      previous: prefix.receipt,
      successor: receipt,
      imported: prefix
    })
  end

  def verify_inputs(context, inputs, settled \\ %{}) do
    result =
      Enum.reduce_while(Enum.sort(inputs.streams), {:ok, %{}}, fn {name,
                                                                   %{
                                                                     descriptor: descriptor,
                                                                     attempts: attempts
                                                                   }},
                                                                  {:ok, streams} ->
        with attempt when not is_nil(attempt) <- Enum.find(attempts, &(!is_nil(&1.receipt))),
             {:ok, spec} <- Serialization.stream_spec(descriptor),
             {:ok, known} <- Receipt.parse(attempt.receipt),
             {:ok, prefix} <-
               verified_prefix(context, inputs.session.id, name, attempt, spec, known, settled),
             true <- prefix.sealed and prefix.index_digest == attempt.digest,
             true <- Receipt.exact_prefix?(known, prefix.receipt),
             {:ok, _} <- Receipt.terminal_receipt(prefix.index, prefix, known) do
          entry = %{
            "digest" => prefix.index_digest,
            "index" => Serialization.to_map(prefix.index),
            "clock" => ClockObservations.freeze(name, spec, inputs.facts)
          }

          {:cont, {:ok, Map.put(streams, name, entry)}}
        else
          _ -> {:halt, {:error, :unverified_stream}}
        end
      end)

    with {:ok, streams} <- result,
         true <-
           Enum.all?(inputs.inventory, fn row ->
             DeviceMeasurement.validate(row["event"]) == :ok and
               Serialization.digest(row["event"]) == row["fingerprint"]
           end),
         :ok <- inventory_matches(inputs.session, inputs.inventory) do
      {:ok, %{inputs: inputs, streams: streams}}
    else
      false -> {:error, :unverified_inventory}
      error -> error
    end
  end

  defp verified_prefix(context, id, name, attempt, spec, known, settled) do
    dir = attempt_dir(context, id, name, attempt.fence)

    case Map.get(settled, name) do
      %MedEx.Storage.RecoveredPrefix{fence: fence, artifact_dir: settled_dir, sealed: true} =
          prefix ->
        if fence == attempt.fence and settled_dir == Path.expand(dir) do
          {:ok, prefix}
        else
          recover_and_reconcile(dir, spec, attempt.fence, known, context.root_owner)
        end

      _ ->
        recover_and_reconcile(dir, spec, attempt.fence, known, context.root_owner)
    end
  end

  defp recover_and_reconcile(dir, spec, fence, known, root_owner) do
    opts = [stream: spec, fence: fence, known_receipt: known, root_owner: root_owner]

    with {:ok, prefix} <- Storage.recover(dir, opts),
         do: reconcile_terminal(dir, opts, prefix)
  end

  defp reconcile_terminal(dir, opts, %{terminal_recorded: true, sealed: false}),
    do: Storage.reconcile_terminal(dir, opts)

  defp reconcile_terminal(_, _, prefix), do: {:ok, prefix}

  def build(%{inputs: inputs, streams: streams}) do
    s = inputs.session

    defects =
      for {name, stream} <- Enum.sort(streams),
          code <- stream_defects(stream),
          do: %{"stream" => name, "code" => code}

    defects =
      defects ++
        for fact <- inputs.facts,
            fact["type"] in ["duplicate_conflict", "quarantine", "interrupted"],
            do: %{"code" => fact["type"], "stream" => fact["body"]["stream"]}

    defects =
      if s.profile == "plx_spot_check" and inputs.inventory == [],
        do: defects ++ [%{"code" => "empty_inventory"}],
        else: defects

    manifest = %{
      "schema" => "medfabric.acquisition-manifest.v2",
      "acquisition" => s.id,
      "encounter" => s.encounter,
      "source_kind" => s.source_kind,
      "principal" => s.principal,
      "profile" => s.profile,
      "site" => s.site,
      "boot" => s.boot,
      "generation" => to_string(s.frozen_generation),
      "repeat_of" => s.repeat_of,
      "streams" => streams,
      "facts" => inputs.facts,
      "inventory" => inputs.inventory,
      "defects" => defects,
      "transport_inventory" => %{
        "sha256" => Serialization.digest(inputs.transport),
        "count" => to_string(length(inputs.transport)),
        "basis" => "server_transport_observation"
      }
    }

    bytes = MedEx.CanonicalJSON.encode(manifest)

    if byte_size(bytes) <= 16_777_216,
      do: {:ok, %{manifest: manifest, bytes: bytes, digest: S.hash(bytes)}},
      else: {:error, :manifest_capacity}
  end

  defp stream_defects(stream) do
    index = stream["index"]

    if(index["terminal"] == "finished", do: [], else: ["interrupted"]) ++
      if(stream["clock"]["state"] == "bounded", do: [], else: ["clock_unavailable"]) ++
      Enum.map(index["spans"], & &1["code"])
  end

  defp inventory_matches(
         %{profile: "plx_spot_check", final_inventory: %{"count" => count, "digest" => digest}},
         entries
       ) do
    if count == to_string(length(entries)) and digest == inventory_digest(entries) and
         Enum.all?(Enum.with_index(entries), fn {row, n} ->
           row["event"]["gateway_sequence"] == to_string(n)
         end), do: :ok, else: {:error, :inventory_pending}
  end

  defp inventory_matches(%{profile: profile, final_inventory: final}, _)
       when profile in ["paired_exam", "browser_microphone"],
       do: if(final == %{}, do: :ok, else: {:error, :invalid_finish})

  defp inventory_matches(_, _), do: {:error, :invalid_inventory}

  def verify_review(context, enc, id, actor, digest) do
    with {:ok, manifest} <- S.manifest(context.db, enc, id, actor, digest),
         {:ok, bytes} <- safe_manifest(context, id),
         true <- S.hash(bytes) == digest and MedEx.CanonicalJSON.encode(manifest) == bytes,
         :ok <- verify_full_streams(context, id, manifest) do
      {:ok,
       %{
         kind: :acquisition,
         id: id,
         encounter: enc,
         digest: digest,
         body: manifest,
         verified: true
       }}
    else
      _ -> {:error, :unverified_manifest}
    end
  end

  def promoted(context, enc, id, actor, digest) do
    with {:ok, manifest} <- S.manifest(context.db, enc, id, actor, digest),
         {:ok, bytes} <- safe_manifest(context, id),
         true <- S.hash(bytes) == digest and MedEx.CanonicalJSON.encode(manifest) == bytes,
         do: {:ok, manifest},
         else: (_ -> {:error, :unverified_manifest})
  end

  defp verify_full_streams(context, id, m) do
    if Enum.all?(m["streams"], fn {name, entry} -> verified_stream?(context, id, name, entry) end),
       do: :ok,
       else: {:error, :unverified_stream}
  end

  defp verified_stream?(context, id, name, entry) do
    with {:ok, spec} <- Serialization.stream_spec(entry["index"]["stream"]),
         {:ok, prefix} <-
           Storage.recover(attempt_dir(context, id, name, entry["index"]["fence"]),
             stream: spec,
             fence: entry["index"]["fence"],
             root_owner: context.root_owner
           ) do
      prefix.sealed and prefix.index_digest == entry["digest"] and
        Serialization.to_map(prefix.index) == entry["index"]
    else
      _ -> false
    end
  end

  defp safe_manifest(context, id) do
    file = Path.join(root(context, id), "manifest.mej1")

    with :ok <- DeviceRootLock.trusted_path(root(context, id)),
         {:ok, %{type: :regular, size: size}} <- File.lstat(file),
         true <- size <= 16_777_216,
         {:ok, bytes} <- File.read(file),
         true <- byte_size(bytes) == size,
         do: {:ok, bytes},
         else: (_ -> {:error, :unsafe_manifest})
  end

  defp install(context, id, bytes) do
    dir = root(context, id)
    :ok = File.mkdir_p(dir)
    :ok = DeviceRootLock.trusted_path(dir)
    {:ok, _} = GenServer.call(context.root_owner, {:med_ex_root_ownership, dir}, 1_000)
    file = Path.join(dir, "manifest.mej1")

    case safe_manifest(context, id) do
      {:ok, ^bytes} ->
        DeviceRootLock.sync_directory(dir)

      {:ok, _} ->
        {:error, :manifest_conflict}

      _ ->
        temp = file <> "." <> S.nonce()

        try do
          with {:ok, :ok} <-
                 File.open(temp, [:write, :binary, :exclusive], fn io ->
                   :ok = IO.binwrite(io, bytes)
                   :file.sync(io)
                 end),
               result = File.ln(temp, file),
               true <-
                 result == :ok or
                   (result == {:error, :eexist} and safe_manifest(context, id) == {:ok, bytes}),
               :ok <- DeviceRootLock.sync_directory(dir),
               {:ok, ^bytes} <- safe_manifest(context, id),
               do: :ok,
               else: (_ -> {:error, :manifest_install_unknown})
        after
          File.rm(temp)
        end
    end
  end

  defp gated(context, id, names, fun) do
    keys = Enum.map(Enum.sort(names), &{id, &1})

    acquired =
      Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, held} ->
        case AcquisitionIngress.acquire_gate(context, elem(key, 0), elem(key, 1)) do
          :ok -> {:cont, {:ok, [key | held]}}
          error -> {:halt, {error, held}}
        end
      end)

    case acquired do
      {:ok, held} ->
        result =
          try do
            fun.()
          catch
            :exit, _ -> {:error, :finalization_unknown}
          end

        case result do
          {:ok, _} -> Enum.each(held, &DeviceRootLock.release(context.root_owner, &1))
          _ -> Enum.each(held, &DeviceRootLock.poison(context.root_owner, &1))
        end

        result

      {error, held} ->
        Enum.each(held, &DeviceRootLock.release(context.root_owner, &1))
        error
    end
  end

  defp finalize_pending(context, id, names) do
    case gated(context, id, names, fn ->
           finalize(context, id)
         end) do
      {:ok, _} = result ->
        result

      {:error, :inventory_pending} = pending ->
        pending

      error ->
        S.settlement_pending(context.db, id)
        error
    end
  end

  defp recover_one(context, id) do
    with {:ok, s} <- S.settlement(context.db, id, fn _, s -> s end) do
      recover_snapshot(context, id, s)
    end
  end

  defp recover_snapshot(context, id, s) do
    if s.authority != "authorized",
      do: settle_interrupted(context, id),
      else: recover_authorized(context, id, s)
  end

  defp recover_authorized(context, id, s) do
    with :ok <- AcquisitionIngress.quiesce(context, id, Map.keys(s.descriptors)),
         do: gated(context, id, Map.keys(s.descriptors), fn -> finalize(context, id) end)
  end

  defp finalize_interrupted(context, id) do
    with {:ok, :ok} <- S.finish_expiry(context.db, id, ClockObservations.wall_mapping()),
         {:ok, _} <- settle_streams(context, id, true) do
      finalize(context, id)
    end
  end

  defp promote_staged(tx, s, id, built) do
    {:ok, staged} = S.staged(tx, id)

    unless staged.bytes == built.bytes and staged.digest == built.digest and
             S.snapshot_digest(S.frozen_inputs(tx, s)) == staged.snapshot,
           do: S.abort(tx, :snapshot_changed)

    Barrier.hit("db_completion", "all", fn -> to_string(Postgres.backend_id(tx)) end)
    S.promote(tx, s, built.digest, built.manifest)
  end

  defp interrupt_writer(tx, writer, attempt, predecessor) do
    with {:ok, observed} <- MedEx.StreamWriter.receipt(writer, attempt.fence, 30_000),
         :ok <- verify_import(predecessor, observed),
         {:ok,
          %MedEx.Storage.Terminal{
            index: index,
            receipt: receipt,
            recovered: recovered
          }} <-
           MedEx.StreamWriter.interrupt(
             writer,
             attempt.fence,
             "authority_ended; trailing_loss_unknown",
             30_000
           ),
         {:ok, ^receipt} <- Receipt.terminal_receipt(index, recovered, observed) do
      S.record_receipt(tx, attempt.fence, receipt, index)
      recovered
    else
      _ -> S.abort(tx, :interrupted_seal_unknown)
    end
  after
    if Process.alive?(writer), do: GenServer.stop(writer, :normal, 30_000)
  end

  defp interrupt_locked(tx, s, opts, attempt, predecessor) do
    unless s.authority != "authorized" and s.frozen_at != nil,
      do: S.abort(tx, :settlement_not_authorized)

    case MedEx.StreamWriter.start_link(opts) do
      {:ok, writer} ->
        interrupt_writer(tx, writer, attempt, predecessor)

      _ ->
        S.abort(tx, :interrupted_seal_unknown)
    end
  end
end
