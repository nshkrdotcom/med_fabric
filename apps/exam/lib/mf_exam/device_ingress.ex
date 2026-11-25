defmodule MedFabric.Exam.DeviceIngress do
  unless Code.ensure_loaded?(MedEx.StreamWriter),
    do:
      raise(
        "Select the MedEx stream-v1 source checkout in .mix_sources.json; the legacy Hex SDK lacks StreamWriter"
      )

  @moduledoc "One independently scheduled writer and one active socket per immutable source stream."
  use GenServer, restart: :temporary
  alias MedEx.{IntegritySpan, SampleFrame, Serialization, StreamIndex, StreamWriter}
  alias MedEx.Storage.File, as: Storage
  alias MedEx.Wire.FrameV1
  alias MedFabric.Exam.{Barrier, DeviceManifest}
  alias MedFabric.Store.DeviceSessions, as: S

  @capacity_reasons ~w(duration_limit artifact_limit frame_limit integrity_span_limit journal_limit)

  def start_link(key),
    do:
      GenServer.start_link(__MODULE__, nil,
        name: {:via, Registry, {MedFabric.Exam.DeviceRegistry, key}}
      )

  def init(nil), do: {:ok, nil}

  def open(bind, name, digest) when name in ["audio", "ecg"] do
    result =
      S.scoped(bind, fn _, session ->
        get_in(session.descriptors, [name, "descriptor_ref"]) == digest
      end)

    case result do
      {:ok, true} -> open_verified(bind, name, digest)
      _ -> {:error, :binding_denied}
    end
  end

  defp open_verified(bind, name, digest) do
    key = {bind.id, name}

    pid =
      case DynamicSupervisor.start_child(MedFabric.Exam.Captures, {__MODULE__, key}) do
        {:ok, p} -> p
        {:error, {:already_started, p}} -> p
      end

    case GenServer.call(pid, {:open, bind, name, digest}, 35_000) do
      {:ok, r} -> {:ok, pid, r}
      e -> e
    end
  end

  def call(pid, op), do: GenServer.call(pid, op, 35_000)

  def handle_call({:open, b, n, digest}, {socket, _}, old) do
    cond do
      old && old.bind.generation > b.generation ->
        {:reply, {:error, :old_generation}, old}

      active_socket?(old, b.generation, socket) ->
        {:reply, {:error, :already_open}, old}

      old && old.bind.generation == b.generation && old.digest == digest &&
          Process.alive?(old.writer) ->
        reopen_socket(b, old, socket)

      true ->
        reserve_and_open(b, n, digest, socket, old)
    end
  end

  def handle_call(:expire, _, nil), do: {:stop, :normal, :ok, nil}

  def handle_call(:expire, _, %{writer: writer} = s) do
    :ok = stop_writer(writer)
    {:stop, :normal, :ok, s}
  end

  def handle_call(op, {socket, _}, %{socket: socket} = s) do
    started = if op == :checkpoint, do: System.monotonic_time(:microsecond)

    result =
      S.scoped(s.bind, fn tx, session ->
        unless session.phase in ["capturing", "finalizing"], do: S.abort(tx, :inactive)

        execute_scoped(tx, op, s)
      end)

    if started do
      :telemetry.execute(
        [:mf_exam, :device_ingress, :checkpoint],
        %{duration_us: System.monotonic_time(:microsecond) - started},
        %{stream: s.name, acquisition_id: s.bind.id}
      )
    end

    case result do
      {:ok, {:sealed, r}} ->
        {:stop, :normal, {:ok, r}, s}

      {:ok, {:capacity, r}} ->
        {:stop, :normal, {:capacity, r}, s}

      {:ok, {:durable, accepted, durable}} ->
        {:reply, {:durable, accepted, durable}, %{s | receipt: durable}}

      {:ok, {:receipt, r}} ->
        {:reply, {:ok, r}, %{s | receipt: r}}

      {:ok, {:error, :duplicate_conflict} = error} ->
        {:stop, :normal, error, s}

      {:ok, error} ->
        {:reply, error, s}

      error ->
        {:reply, error, s}
    end
  end

  def handle_call(_, _, s), do: {:reply, {:error, :stale_socket}, s}

  defp active_socket?(%{bind: %{generation: generation}, socket: previous}, generation, socket),
    do: previous != socket and Process.alive?(previous)

  defp active_socket?(_, _, _), do: false

  defp reopen_socket(bind, s, socket) do
    result =
      S.scoped(bind, fn tx, session ->
        unless session.phase in ["capturing", "finalizing"], do: S.abort(tx, :inactive)

        case StreamWriter.receipt(s.writer) do
          {:ok, receipt} when receipt == s.receipt -> {:receipt, receipt}
          {:ok, _} -> execute_scoped(tx, :checkpoint, s)
          error -> error
        end
      end)

    case result do
      {:ok, {:receipt, receipt}} ->
        {:reply, {:ok, receipt}, %{s | socket: socket, receipt: receipt}}

      {:ok, error} ->
        {:reply, error, s}

      error ->
        {:reply, error, s}
    end
  end

  defp reserve_and_open(bind, name, digest, socket, old) do
    case S.scoped(bind, &reserve(&1, &2, bind, name, digest, old), :update) do
      {:ok, {:sealed, receipt}} ->
        {:stop, :normal, {:error, {:sealed, receipt}}, old}

      {:ok, {:reserved, fence, spec, number, previous}} ->
        case open_writer(bind, name, fence, spec, previous) do
          {:ok, writer, receipt} ->
            new = %{
              writer: writer,
              bind: bind,
              name: name,
              socket: socket,
              spec: spec,
              number: number,
              digest: digest,
              fence: fence,
              receipt: receipt
            }

            {:reply, {:ok, receipt}, new}

          error ->
            {:stop, :normal, error, old}
        end

      error ->
        {:reply, error, old}
    end
  end

  defp reserve(tx, session, bind, name, digest, old) do
    unless session.profile == "paired_exam" and
             session.phase in ["capturing", "finalizing", "sealed"],
           do: S.abort(tx, :inactive)

    {:ok, spec} = Serialization.stream_spec(session.descriptors[name])
    if spec.descriptor_ref != digest, do: S.abort(tx, :descriptor_changed)
    if old, do: stop_writer(old.writer)

    previous =
      S.rows(
        tx,
        "SELECT fence,receipt,sealed_index FROM stream_attempts WHERE acquisition_id=$1 AND stream=$2 ORDER BY generation DESC LIMIT 1 FOR UPDATE",
        [bind.id, name]
      )

    case prior(tx, previous, bind.id, name, spec) do
      {:sealed, receipt} ->
        {:sealed, receipt}

      predecessor ->
        fence = S.nonce()
        number = if name == "audio", do: 1, else: 2

        # Commit the reservation before opening a new writable directory.
        S.rows(
          tx,
          "INSERT INTO stream_attempts(acquisition_id,stream,number,generation,fence) VALUES($1,$2,$3,$4,$5)",
          [bind.id, name, number, bind.generation, fence]
        )

        {:reserved, fence, spec, number, predecessor}
    end
  end

  defp stop_writer(writer) do
    # Rotation and expiry have already fenced this attempt. Its volatile tail
    # belongs to the client spool and must not be flushed during handoff.
    GenServer.stop(writer, :normal, 30_000)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _} -> :ok
  end

  defp open_writer(bind, name, fence, spec, previous) do
    opts = [
      owner: self(),
      stream: spec,
      fence: fence,
      limits: %{checkpoint_ms: :manual},
      artifact_dir: DeviceManifest.attempt_dir(bind.id, name, fence),
      fault_hook: fn stage -> Barrier.hit(to_string(stage), name) end
    ]

    case S.scoped(bind, fn tx, _ ->
           with {:ok, writer} <- StreamWriter.start_link(opts ++ previous),
                {:ok, receipt} <- StreamWriter.receipt(writer) do
             S.rows(tx, "UPDATE stream_attempts SET receipt=$2 WHERE fence=$1", [
               fence,
               Serialization.to_map(receipt)
             ])

             {:ok, writer, receipt}
           end
         end) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp execute_scoped(tx, {:frame, raw}, s) do
    Barrier.hit("writer_stall", s.name)
    payload = max(0, byte_size(raw) - 48)

    with {:ok, f} <- FrameV1.decode(raw),
         true <- f.stream_number == s.number and f.source_epoch == s.spec.source_epoch do
      frame =
        struct!(
          SampleFrame,
          Map.merge(
            Map.take(Map.from_struct(f), [
              :source_epoch,
              :sequence,
              :first_sample,
              :sample_count,
              :config_epoch,
              :payload
            ]),
            %{descriptor_ref: s.digest, stream_id: s.name}
          )
        )

      record_result(tx, {:frame, raw, f, payload}, StreamWriter.push(s.writer, frame), s)
    else
      _ -> {:error, :wrong_frame}
    end
  end

  defp execute_scoped(tx, op, s), do: record_result(tx, op, act(op, s), s)

  defp record_result(tx, _op, {:ok, %StreamIndex{} = index}, s) do
    {^index, receipt} = store_sealed(tx, s)
    {:sealed, receipt}
  end

  defp record_result(tx, :checkpoint, {:ok, receipt}, s) do
    Barrier.hit("journal_sync", s.name)

    S.rows(tx, "UPDATE device_limits_observed SET durable_acks=durable_acks+1 WHERE fence=$1", [
      s.fence
    ])

    S.rows(tx, "UPDATE stream_attempts SET receipt=$2 WHERE fence=$1", [
      s.fence,
      Serialization.to_map(receipt)
    ])

    {:receipt, receipt}
  end

  defp record_result(tx, op, {:ok, receipt}, s) do
    observe_transport(tx, op, s)
    usage = StreamWriter.stats(s.writer)
    flushed? = receipt.journal_generation > s.receipt.journal_generation

    payload =
      case op do
        {:frame, _, _, size} -> size
        _ -> 0
      end

    if flushed?, do: Barrier.hit("journal_sync", s.name)
    ack_inc = if flushed?, do: 1, else: 0

    S.rows(
      tx,
      """
      INSERT INTO device_limits_observed(fence,max_frame_bytes,max_pending_bytes,max_pending_frames,durable_acks)
      VALUES($1,$2,$3,$4,$5)
      ON CONFLICT(fence) DO UPDATE SET
        max_frame_bytes=greatest(device_limits_observed.max_frame_bytes,$2),
        max_pending_bytes=greatest(device_limits_observed.max_pending_bytes,$3),
        max_pending_frames=greatest(device_limits_observed.max_pending_frames,$4),
        durable_acks=device_limits_observed.durable_acks+$5
      """,
      [
        s.fence,
        payload,
        max(payload, usage.peak_pending_bytes),
        max(1, usage.peak_pending_frames),
        ack_inc
      ]
    )

    if flushed? do
      durable = durable_prefix(receipt)

      S.rows(tx, "UPDATE stream_attempts SET receipt=$2 WHERE fence=$1", [
        s.fence,
        Serialization.to_map(durable)
      ])

      {:durable, receipt, durable}
    else
      {:receipt, receipt}
    end
  end

  defp record_result(tx, _op, {:error, :duplicate_conflict} = error, s) do
    store_sealed(tx, s)
    S.fact(tx, s.bind.id, "duplicate_conflict", %{"stream" => s.name})
    error
  end

  defp record_result(tx, _op, {:error, {:capacity, reason}}, s) do
    {index, receipt} = store_sealed(tx, s)

    if index.terminal == :interrupted and index.terminal_reason == reason,
      do: {:capacity, receipt},
      else: S.abort(tx, :unexpected_terminal)
  end

  defp record_result(_, _, error, _), do: error

  defp durable_prefix(receipt) do
    %{
      receipt
      | accepted_sequence: receipt.durable_sequence,
        accepted_sample: receipt.durable_sample
    }
  end

  defp observe_transport(tx, {:frame, raw, frame, _payload}, s) do
    if s.name == "ecg" and :ets.whereis(:mf_live_ecg) != :undefined do
      :ets.insert(:mf_live_ecg, {s.bind.id, System.monotonic_time(:millisecond), s.spec, frame})
    end

    S.rows(
      tx,
      "INSERT INTO device_transport_observations(fence,sequence,raw_digest) VALUES($1,$2,$3) ON CONFLICT DO NOTHING",
      [s.fence, frame.sequence, S.hash(raw)]
    )
  end

  defp observe_transport(_, _, _), do: :ok

  defp store_sealed(tx, s) do
    await_dead(s.writer)
    dir = DeviceManifest.attempt_dir(s.bind.id, s.name, s.fence)

    [[known]] = S.rows(tx, "SELECT receipt FROM stream_attempts WHERE fence=$1", [s.fence])
    {:ok, known_receipt} = Serialization.receipt(known)

    {:ok, %{sealed: true, index: index, receipt: receipt}} =
      Storage.recover(dir, stream: s.spec, fence: s.fence, known_receipt: known_receipt)

    S.rows(
      tx,
      "UPDATE stream_attempts SET sealed_index=$2,index_digest=$3,receipt=$4 WHERE fence=$1",
      [
        s.fence,
        Serialization.to_map(index),
        Serialization.digest(index),
        Serialization.to_map(receipt)
      ]
    )

    {index, receipt}
  end

  defp act(
         {:gap,
          %{
            "id" => id,
            "first" => a,
            "end" => b,
            "first_sequence" => q,
            "next_sequence" => r,
            "irreversible" => true,
            "cause" => cause
          }},
         s
       )
       when is_binary(cause) and byte_size(cause) <= 256 do
    span = %IntegritySpan{
      stream_id: s.name,
      source_epoch: s.spec.source_epoch,
      code: :source_gap,
      source: "handheld",
      first_sample: uint(a),
      end_sample: uint(b),
      context: %{"cause" => cause}
    }

    StreamWriter.record_gap(s.writer, %{
      id: id,
      span: span,
      first_sequence: uint(q),
      next_sequence: uint(r),
      irreversible: true
    })
  end

  defp act(:checkpoint, s) do
    started = System.monotonic_time(:microsecond)
    result = StreamWriter.checkpoint(s.writer)

    :telemetry.execute(
      [:mf_exam, :device_ingress, :writer_checkpoint],
      %{duration_us: System.monotonic_time(:microsecond) - started},
      %{stream: s.name, acquisition_id: s.bind.id}
    )

    result
  end

  defp act({:finish, seq, count, interruption}, s) do
    with {:ok, r} <- StreamWriter.checkpoint(s.writer),
         true <- {uint(seq), uint(count)} == {r.durable_sequence, r.durable_sample} do
      if interruption in ["spool_full", "source_reset"],
        do: StreamWriter.interrupt(s.writer, interruption),
        else: StreamWriter.finish(s.writer)
    else
      _ -> {:error, :finish_mismatch}
    end
  end

  defp act(_, _), do: {:error, :unsupported}

  defp uint(s) when is_binary(s) and byte_size(s) in 1..20 do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> :invalid
    end
  end

  defp uint(_), do: :invalid

  defp await_dead(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      30_000 -> raise "prior writer not quiescent"
    end
  end

  def handle_info({:med_ex_durable, pid, r}, %{writer: pid} = s) do
    if r.fence == s.fence do
      S.scoped(s.bind, fn tx, _ ->
        S.rows(
          tx,
          "UPDATE stream_attempts SET receipt=$2 WHERE fence=$1 AND coalesce((receipt->>'journal_generation')::bigint,0)<$3",
          [s.fence, Serialization.to_map(r), r.journal_generation]
        )
      end)
    end

    {:noreply, s}
  end

  def handle_info({:med_ex_storage_failed, pid, _}, %{writer: pid} = s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  defp prior(_, [], _, _, _), do: []

  defp prior(tx, [[_, receipt, index]], _, _, _) when not is_nil(index) do
    case Serialization.receipt(receipt) do
      {:ok, receipt} -> {:sealed, receipt}
      _ -> S.abort(tx, :unverified_receipt)
    end
  end

  defp prior(tx, [[fence, known, nil]], id, name, spec) do
    dir = DeviceManifest.attempt_dir(id, name, fence)

    if is_nil(known) and not File.exists?(dir) do
      # Crash after reserving a successor but before opening it. Walk past this
      # empty reservation. Its predecessor may already contain durable samples.
      prev =
        S.rows(
          tx,
          "SELECT fence,receipt,sealed_index FROM stream_attempts WHERE acquisition_id=$1 AND stream=$2 AND generation<(SELECT generation FROM stream_attempts WHERE fence=$3) ORDER BY generation DESC LIMIT 1",
          [id, name, fence]
        )

      prior(tx, prev, id, name, spec)
    else
      opts =
        [stream: spec, fence: fence] ++
          if(known, do: [known_receipt: elem(Serialization.receipt(known), 1)], else: [])

      recovery =
        case Storage.recover(dir, opts) do
          {:ok, %{terminal_recorded: true, sealed: false}} ->
            Storage.reconcile_index(dir, opts)

          result ->
            result
        end

      case recovery do
        {:ok,
         %{sealed: true, index: %{terminal: terminal, terminal_reason: reason} = i, receipt: r}}
        when terminal in [:finished, :failed] or
               (terminal == :interrupted and reason in @capacity_reasons) ->
          S.rows(
            tx,
            "UPDATE stream_attempts SET sealed_index=$2,index_digest=$3,receipt=$4 WHERE fence=$1",
            [fence, Serialization.to_map(i), Serialization.digest(i), Serialization.to_map(r)]
          )

          {:sealed, r}

        {:ok, %{receipt: r}} ->
          [predecessor: %{artifact_dir: dir, receipt: r}]

        _ ->
          S.abort(tx, :unverified_predecessor)
      end
    end
  end
end
