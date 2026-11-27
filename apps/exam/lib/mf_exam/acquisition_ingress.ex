defmodule MedFabric.Exam.AcquisitionIngress do
  @moduledoc "One owner per logical stream. The root effect gate precedes SQL and survives uncertain operations."
  use GenServer, restart: :temporary
  alias MedEx.{Receipt, SampleFrame, Serialization, StreamWriter}
  alias MedEx.Storage.File, as: Storage
  alias MedEx.Wire.FrameV1
  alias MedFabric.Domain.Review

  alias MedFabric.Exam.{
    Acquisition,
    AcquisitionManifest,
    AcquisitionWorkflow,
    Barrier,
    DeviceRootLock
  }

  alias MedFabric.Store.AcquisitionSessions, as: S
  alias MedFabric.Store.Postgres
  @timeout 30_000

  def start_link({context, key}),
    do:
      GenServer.start_link(__MODULE__, {context, key},
        name: {:via, Registry, {context.registry, key}}
      )

  def init({context, key}),
    do:
      {:ok,
       %{
         context: context,
         key: key,
         writer: nil,
         bind: nil,
         receipt: nil,
         attempt: nil,
         spec: nil,
         socket: nil,
         monitor: nil,
         gate: false
       }}

  def open(context, bind, name, digest) when name in ["audio", "ecg"] do
    case DynamicSupervisor.start_child(context.writers, {__MODULE__, {context, {bind.id, name}}}) do
      {:ok, pid} -> open_call(pid, bind, name, digest)
      {:error, {:already_started, pid}} -> open_call(pid, bind, name, digest)
      _ -> {:error, :ingress_unavailable}
    end
  end

  def open(_, _, _, _), do: {:error, :unknown_stream}

  defp open_call(pid, bind, name, digest) do
    case GenServer.call(pid, {:open, bind, name, digest}, 40_000) do
      {:ok, result} -> {:ok, pid, result}
      error -> error
    end
  catch
    :exit, _ -> {:error, :ingress_outcome_unknown}
  end

  def call(pid, operation), do: GenServer.call(pid, operation, 40_000)

  def quiesce(context, id, streams) do
    Enum.reduce_while(Enum.sort(streams), :ok, fn name, :ok ->
      quiesce_stream(context, id, name)
    end)
  end

  def handle_call({:open, bind, name, digest}, {socket, _}, s) do
    with true <- valid_open?(s.context, bind, name, digest),
         :ok <- acquire_gate(s.context, bind.id, name),
         :ok <- retire_writer(s),
         {:ok, {attempt, spec, prior}} <- reserve(s.context, bind, name, digest),
         {:ok, result, writer} <- start_reserved(s.context, bind, name, attempt, spec, prior) do
      if s.monitor, do: Process.demonitor(s.monitor, [:flush])
      :ok = DeviceRootLock.bind_connection(s.context.root_owner, s.key, bind.connection, socket)

      next = %{
        s
        | gate: true,
          writer: writer,
          bind: bind,
          socket: socket,
          monitor: Process.monitor(socket),
          attempt: attempt,
          spec: spec,
          receipt: result.receipt
      }

      if result.terminal do
        DeviceRootLock.release(s.context.root_owner, s.key)
        {:stop, :normal, {:ok, result}, %{next | gate: false, writer: nil}}
      else
        {:reply, {:ok, result}, next}
      end
    else
      false ->
        if(s.writer,
          do: {:reply, {:error, :stale_binding}, s},
          else: {:stop, :normal, {:error, :stale_binding}, s}
        )

      {:error, reason} = error
      when reason in [:readmission_required, :invalid_stream, :inactive, :attempt_capacity] ->
        DeviceRootLock.release(s.context.root_owner, s.key)
        {:stop, :normal, error, %{s | gate: false, writer: nil}}

      error ->
        {:stop, :normal, error, %{s | gate: true}}
    end
  end

  def handle_call(:retire, _, s) do
    case retire_writer(s) do
      :ok ->
        if s.gate, do: DeviceRootLock.release(s.context.root_owner, s.key)
        {:stop, :normal, :ok, %{s | writer: nil, gate: false}}

      error ->
        {:stop, :normal, error, s}
    end
  end

  def handle_call(op, {socket, _}, %{socket: socket, writer: writer} = s) when is_pid(writer) do
    result = protected(s, op)

    case result do
      {:ok, %{receipt: receipt} = value} ->
        reply_to_effect(s, op, value, receipt)

      {:error, {:not_committed, _}} = error ->
        {:reply, error, s}

      {:error, reason} = error
      when reason in [:invalid_frame, :invalid_gap, :finish_mismatch, :illegal_transition] ->
        {:reply, error, s}

      _ ->
        retire_writer(s)
        {:stop, :normal, {:error, :outcome_unknown}, s}
    end
  end

  def handle_call(_, _, s), do: {:reply, {:error, :stale_connection}, s}

  defp valid_open?(context, bind, name, digest) do
    match?(
      {:ok, true},
      S.scoped(context.db, bind, fn _, snapshot ->
        case Serialization.stream_spec(snapshot.descriptors[name]) do
          {:ok, spec} -> spec.descriptor_ref == digest
          _ -> false
        end
      end)
    )
  end

  def acquire_gate(context, id, name) do
    key = {id, name}

    case DeviceRootLock.gate(context.root_owner, key) do
      :ok ->
        :ok

      {:error, :prior_effect_quiescence_required} ->
        with :ok <- DeviceRootLock.recover_gate(context.root_owner, key),
             {:ok, {spec, attempts}} <-
               gate_settlement(context, id, name),
             {:ok, %MedEx.Storage.RecoveredPrefix{} = prefix} <-
               recover_previous(context, id, name, spec, attempts) do
          DeviceRootLock.settle_gate(context.root_owner, key, prefix)
        end

      error ->
        error
    end
  end

  defp reserve(context, bind, name, digest) do
    S.scoped(
      context.db,
      bind,
      fn tx, snapshot ->
        with {:ok, spec} <- Serialization.stream_spec(snapshot.descriptors[name]),
             true <- spec.descriptor_ref == digest do
          reserve_attempt(tx, snapshot, bind.id, name, spec)
        else
          _ -> S.abort(tx, :invalid_stream)
        end
      end,
      :update
    )
  end

  defp start_reserved(context, bind, name, attempt, spec, prior) do
    with {:ok, predecessor} <- recover_previous(context, bind.id, name, spec, [attempt | prior]),
         true <- is_nil(predecessor) or not predecessor.sealed do
      open_reserved_writer(context, bind, name, attempt, spec, predecessor)
    else
      false ->
        with {:ok, prefix} <- recover_previous(context, bind.id, name, spec, [attempt | prior]) do
          {:ok,
           %{
             receipt: prefix.receipt,
             terminal: true,
             durable: true,
             index_digest: prefix.index_digest,
             terminal_kind: prefix.index.terminal,
             handoff: nil
           }, nil}
        end

      error ->
        error
    end
  end

  defp recover_previous(_, _, _, _, []), do: {:ok, nil}

  defp recover_previous(context, id, name, spec, [a | rest]) do
    dir = AcquisitionManifest.attempt_dir(context, id, name, a.fence)

    if is_nil(a.receipt) and not File.exists?(dir) do
      recover_previous(context, id, name, spec, rest)
    else
      opts = [stream: spec, fence: a.fence, root_owner: context.root_owner]

      opts = recovery_options(opts, a.receipt)

      with {:ok, prefix} <- Storage.recover(dir, opts),
           {:ok, prefix} <- terminal_index(dir, opts, prefix),
           {:ok, _} <-
             settle_recovered(context, id, a.fence, prefix) do
        {:ok, prefix}
      end
    end
  end

  defp terminal_index(dir, opts, %{terminal_recorded: true, sealed: false}),
    do: Storage.reconcile_terminal(dir, opts)

  defp terminal_index(_, _, prefix), do: {:ok, prefix}

  defp protected(s, op) do
    S.scoped(s.context.db, s.bind, fn tx, current ->
      protected_effect(tx, current, s, op)
    end)
    |> flatten_result()
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :outcome_unknown}
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp flatten_result({:ok, {:error, _} = error}), do: error
  defp flatten_result(result), do: result

  defp effect(s, {:frame, raw}) do
    with {:ok, f} <- FrameV1.decode(raw),
         true <- f.stream_number == s.attempt.number and f.source_epoch == s.spec.source_epoch do
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
            %{stream_id: s.spec.stream_id, descriptor_ref: s.spec.descriptor_ref}
          )
        )

      StreamWriter.push(s.writer, s.attempt.fence, frame, @timeout)
    else
      _ -> {:error, :invalid_frame}
    end
  end

  defp effect(s, {:gap, msg}) do
    with {:ok, a} <- counter(msg["first"]),
         {:ok, b} <- counter(msg["end"]),
         {:ok, q} <- counter(msg["first_sequence"]),
         {:ok, n} <- counter(msg["next_sequence"]),
         true <- msg["irreversible"] == true do
      gap = %{
        id: msg["id"],
        first_sequence: q,
        next_sequence: n,
        irreversible: true,
        span: %MedEx.IntegritySpan{
          stream_id: s.spec.stream_id,
          source_epoch: s.spec.source_epoch,
          code: :source_gap,
          source: to_string(s.bind.source_kind),
          first_sample: a,
          end_sample: b,
          context: %{"cause" => msg["cause"]}
        }
      }

      StreamWriter.record_gap(s.writer, s.attempt.fence, gap, @timeout)
    else
      _ -> {:error, :invalid_gap}
    end
  end

  defp effect(s, :checkpoint), do: StreamWriter.checkpoint(s.writer, s.attempt.fence, @timeout)

  defp effect(s, {:finish, _, _, nil}),
    do: StreamWriter.finish(s.writer, s.attempt.fence, @timeout)

  defp effect(s, {:finish, _, _, reason}) when is_binary(reason),
    do: StreamWriter.interrupt(s.writer, s.attempt.fence, reason, @timeout)

  defp effect(_, _), do: {:error, :unsupported}

  defp finish_covered?(s, {:finish, q, n, _}) do
    with {:ok, sequence} <- counter(q),
         {:ok, sample} <- counter(n),
         {:ok, r} <- StreamWriter.receipt(s.writer, s.attempt.fence, @timeout),
         do:
           Receipt.durable?(r) and r == s.receipt and
             {sequence, sample} == {r.durable_sequence, r.durable_sample}
  end

  defp finish_covered?(_, _), do: false
  defp counter(value), do: Review.counter(value)

  defp retire_writer(%{writer: nil}), do: :ok

  defp retire_writer(s) do
    if Process.alive?(s.writer), do: GenServer.stop(s.writer, :normal, @timeout)
    opts = [stream: s.spec, fence: s.attempt.fence, root_owner: s.context.root_owner]

    case Storage.recover(
           AcquisitionManifest.attempt_dir(s.context, s.bind.id, elem(s.key, 1), s.attempt.fence),
           opts
         ) do
      {:ok, prefix} ->
        settle_retired_writer(s, prefix)

      _ ->
        {:error, :prior_effect_not_quiescent}
    end
  catch
    :exit, _ -> {:error, :prior_effect_not_quiescent}
  end

  defp snapshot(s),
    do:
      Map.merge(s, %{
        now: DateTime.utc_now(),
        current_binding: true,
        quiescent: true,
        reserved: true,
        writer_open: false,
        final_covered: false
      })

  defp publish_optional(s, {:frame, raw}) do
    AcquisitionWorkflow.publish(s.bind, s.spec, raw)
  end

  defp publish_optional(_, _), do: :ok

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = s) do
    case retire_writer(s) do
      :ok ->
        DeviceRootLock.release(s.context.root_owner, s.key)
        {:stop, :normal, %{s | writer: nil, gate: false}}

      _ ->
        {:stop, :normal, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  def terminate(_, s) do
    if s.writer && Process.alive?(s.writer), do: Process.exit(s.writer, :shutdown)
    :ok
  end

  defp quiesce_stream(context, id, name) do
    case Registry.lookup(context.registry, {id, name}) do
      [{pid, _}] ->
        quiesce_result(call(pid, :retire))

      [] ->
        quiesce_unowned(context, id, name)
    end
  end

  defp quiesce_result(:ok), do: {:cont, :ok}
  defp quiesce_result(error), do: {:halt, error}

  defp quiesce_unowned(context, id, name) do
    case acquire_gate(context, id, name) do
      :ok ->
        DeviceRootLock.release(context.root_owner, {id, name})
        {:cont, :ok}

      error ->
        {:halt, error}
    end
  end

  defp reply_to_effect(s, op, value, receipt) do
    if Map.get(value, :terminal) do
      case retire_writer(%{s | receipt: receipt}) do
        :ok ->
          DeviceRootLock.release(s.context.root_owner, s.key)
          {:stop, :normal, {:ok, value}, %{s | writer: nil, gate: false, receipt: receipt}}

        error ->
          {:stop, :normal, error, s}
      end
    else
      publish_optional(s, op)
      {:reply, {:ok, value}, %{s | receipt: Receipt.durable_prefix(receipt)}}
    end
  end

  defp gate_inputs(tx, s, id, name) do
    {:ok, spec} = Serialization.stream_spec(s.descriptors[name])
    {spec, S.attempts(tx, id, name)}
  end

  defp reserve_attempt(tx, snapshot, id, name, spec) do
    old = S.attempts(tx, id, name)

    attempt =
      case Enum.find(old, &(&1.state == "terminal")) do
        nil ->
          reserve_active_attempt(tx, snapshot, name)

        terminal ->
          terminal
      end

    {attempt, spec, Enum.reject(old, &(&1.fence == attempt.fence))}
  end

  defp reserve_active_attempt(tx, current, name) do
    case Acquisition.plan(snapshot(current), :reserve) do
      {:ok, _} -> :ok
      _ -> S.abort(tx, :inactive)
    end

    S.reserve_attempt(tx, current, name)
  end

  defp writer_handoff(predecessor, attempt, previous_receipt, receipt) do
    if predecessor && predecessor.fence != attempt.fence do
      :ok =
        Receipt.handoff(previous_receipt, receipt, %{
          authority: :verified_storage,
          authenticated: true,
          quiescent: true,
          previous: previous_receipt,
          successor: receipt,
          imported: predecessor
        })
    end

    if predecessor && predecessor.fence != attempt.fence,
      do: %{
        "previous" => Receipt.to_map(previous_receipt),
        "successor" => Receipt.to_map(receipt),
        "imported" => Receipt.to_map(previous_receipt),
        "asserted_by" => "authenticated_host"
      }
  end

  defp open_reserved_writer(context, bind, name, attempt, spec, predecessor) do
    if predecessor && predecessor.fence == attempt.fence do
      {:error, :readmission_required}
    else
      previous_receipt = if predecessor, do: predecessor.receipt

      opts = [
        owner: self(),
        fence: attempt.fence,
        stream: spec,
        artifact_dir: AcquisitionManifest.attempt_dir(context, bind.id, name, attempt.fence),
        limits: %{checkpoint_ms: :manual},
        root_owner: context.root_owner
      ]

      opts =
        if predecessor && predecessor.fence != attempt.fence,
          do: Keyword.put(opts, :predecessor, predecessor),
          else: opts

      result =
        S.scoped(context.db, bind, fn tx, _ -> start_writer(tx, opts, attempt) end)

      case result do
        {:ok, %{writer: writer, receipt: receipt}} ->
          handoff = writer_handoff(predecessor, attempt, previous_receipt, receipt)

          {:ok, %{receipt: receipt, handoff: handoff, terminal: false}, writer}

        error ->
          error
      end
    end
  end

  defp start_writer(tx, opts, attempt) do
    with {:ok, writer} <- StreamWriter.start_link(opts),
         {:ok, receipt} <- StreamWriter.receipt(writer, attempt.fence, @timeout),
         true <- Receipt.durable?(receipt) do
      S.record_receipt(tx, attempt.fence, receipt)
      %{writer: writer, receipt: receipt}
    else
      _ -> S.abort(tx, :writer_open_unknown)
    end
  end

  defp record_recovered_prefix(tx, fence, prefix) do
    S.record_receipt(tx, fence, prefix.receipt, if(prefix.sealed, do: prefix.index))
    unless prefix.sealed, do: S.mark_attempt(tx, fence, "quiescent")
    prefix
  end

  defp admitted_effect(tx, s, op, operation) do
    Barrier.hit("effect_admitted", elem(s.key, 1), fn ->
      to_string(Postgres.backend_id(tx))
    end)

    Barrier.hit("writer_stall", elem(s.key, 1), fn ->
      to_string(Postgres.backend_id(tx))
    end)

    started = System.monotonic_time(:microsecond)
    result = effect(s, op)
    elapsed = System.monotonic_time(:microsecond) - started

    if operation == :checkpoint and match?({:ok, %Receipt{}}, result) do
      :telemetry.execute(
        [:mf_exam, :acquisition_ingress, :writer_checkpoint],
        %{duration_us: elapsed},
        %{stream: elem(s.key, 1), fence: s.attempt.fence}
      )
    end

    result
  end

  defp record_effect_receipt(tx, s, op, receipt) do
    durable = Receipt.durable_prefix(receipt)

    case Receipt.observe(s.receipt, durable) do
      :ok -> :ok
      _ -> S.abort(tx, :receipt_conflict)
    end

    S.record_receipt(tx, s.attempt.fence, durable)

    if match?({:frame, _}, op) do
      {:frame, raw} = op
      {:ok, frame} = FrameV1.decode(raw)
      S.transport(tx, s.attempt.fence, frame.sequence, raw)
    end

    if Receipt.durable?(receipt) do
      Barrier.hit("after_object_install", elem(s.key, 1))

      Barrier.hit("journal_sync", elem(s.key, 1), fn ->
        to_string(Postgres.backend_id(tx))
      end)
    else
      Barrier.hit("accepted_before_durable", elem(s.key, 1))
    end

    %{receipt: receipt, terminal: false, durable: Receipt.durable?(receipt)}
  end

  defp record_effect(tx, s, op, result) do
    case result do
      {:ok, %Receipt{} = receipt} ->
        record_effect_receipt(tx, s, op, receipt)

      {:ok, %MedEx.Storage.Terminal{index: index, receipt: receipt, recovered: prefix}} ->
        case Receipt.terminal_receipt(index, prefix, s.receipt) do
          {:ok, ^receipt} ->
            S.record_receipt(tx, s.attempt.fence, receipt, index)

            %{
              receipt: receipt,
              terminal: true,
              durable: true,
              index_digest: Serialization.digest(index)
            }

          _ ->
            S.abort(tx, :terminal_conflict)
        end

      error ->
        error
    end
  end

  defp protected_effect(tx, current, s, op) do
    operation = effect_operation(op)

    snapshot =
      Map.merge(snapshot(current), %{
        writer_open: true,
        final_covered: operation != :finish or finish_covered?(s, op)
      })

    case Acquisition.plan(snapshot, operation) do
      {:ok, _} ->
        result = admitted_effect(tx, s, op, operation)

        record_effect(tx, s, op, result)

      error ->
        error
    end
  end

  defp settle_retired_writer(s, prefix) do
    case S.settlement(s.context.db, s.bind.id, fn tx, _ ->
           record_recovered_prefix(tx, s.attempt.fence, prefix)
           :ok
         end) do
      {:ok, :ok} -> :ok
      _ -> {:error, :settlement_unknown}
    end
  end

  defp recovery_options(opts, receipt) do
    case receipt do
      nil ->
        opts

      wire ->
        case Receipt.parse(wire) do
          {:ok, r} -> Keyword.put(opts, :known_receipt, r)
          _ -> Keyword.put(opts, :known_receipt, :invalid)
        end
    end
  end

  defp gate_settlement(context, id, name) do
    S.settlement(context.db, id, fn tx, s -> gate_inputs(tx, s, id, name) end)
  end

  defp settle_recovered(context, id, fence, prefix) do
    S.settlement(context.db, id, fn tx, _ -> record_recovered_prefix(tx, fence, prefix) end)
  end

  defp effect_operation({:frame, _}), do: :push
  defp effect_operation({:gap, _}), do: :gap
  defp effect_operation({:finish, _, _, _}), do: :finish
  defp effect_operation(:checkpoint), do: :checkpoint
  defp effect_operation(_), do: :invalid
end
