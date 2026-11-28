defmodule MedFabric.ExamWeb.AcquisitionSocket do
  @moduledoc false
  @behaviour WebSock
  alias MedEx.{Receipt, Serialization}
  alias MedEx.Wire.{Control, Credit, FrameV1}

  alias MedFabric.Domain.Review

  alias MedFabric.Exam.{
    AcquisitionIngress,
    AcquisitionManifest,
    Barrier,
    ClockObservations,
    DeviceRootLock,
    PersistedFrame,
    PreviewGateway
  }

  alias MedFabric.Store.AcquisitionSessions, as: S
  alias MedFabric.Store.{DeviceCommands, MeasurementEvents}

  @ops ~w(hello open_stream open_monitor heartbeat result measurement probe probe_reply anchor status collection_finish finish_acquisition gap checkpoint finish)
  @gap_keys ~w(id first end first_sequence next_sequence irreversible cause)

  def upgrade(conn, context, principal, kind) do
    WebSockAdapter.upgrade(
      conn,
      __MODULE__,
      %{
        context: context,
        principal: principal,
        kind: kind,
        bind: nil,
        binding: nil,
        writer: nil,
        receipt: nil,
        ledger: nil,
        flush: nil,
        probe: nil,
        frames: 15,
        bytes: 262_144,
        max_frame_bytes: 0,
        max_payload_bytes: 0,
        max_pending_bytes: 0,
        max_pending_frames: 0,
        operation_id: "initial"
      },
      max_frame_size: 65_584,
      timeout: 35_000
    )
  end

  def init(state), do: {:ok, state}

  def handle_in({raw, [opcode: :text]}, s) when byte_size(raw) <= 16_384 do
    with {:ok, msg} <- Control.decode(raw, @ops),
         true <- initial?(msg, s) or msg["binding"] == s.binding do
      state = %{s | operation_id: msg["operation_id"] || "initial"}
      dispatch_text(msg["type"], msg, state, raw)
    else
      _ -> denied(s)
    end
  rescue
    _ in [ArgumentError, KeyError, FunctionClauseError, MatchError] -> denied(s)
  catch
    :exit, _ -> denied(s)
  end

  def handle_in({raw, [opcode: :binary]}, %{writer: writer} = s)
      when is_pid(writer) and byte_size(raw) <= 65_584 do
    with {:ok, frame} <- FrameV1.decode(raw),
         true <- PersistedFrame.valid?(frame) do
      operation = %{
        id: "frame-#{frame.sequence}-#{frame.first_sample}",
        fingerprint: S.hash(raw),
        bytes: byte_size(raw),
        sequence: frame.sequence + 1,
        sample: frame.first_sample + frame.sample_count
      }

      record(s, operation, {:frame, raw}, byte_size(frame.payload))
    else
      _ -> denied(s)
    end
  catch
    :exit, _ -> denied(s)
  end

  def handle_in({raw, [opcode: :binary]}, %{kind: :monitor, bind: bind} = s) when is_map(bind) do
    with {:ok, frame} <- FrameV1.decode(raw),
         true <- frame.stream_number == 3,
         {:ok, spec} <-
           S.scoped(
             s.context.db,
             bind,
             fn tx, current -> monitor_spec(tx, current, frame) end,
             :read
           ) do
      PreviewGateway.feed(bind, spec, raw)
      encode_reply("monitor_credit", %{"credit_frames" => 1, "credit_bytes" => 1968}, s)
    else
      _ -> denied(s)
    end
  end

  def handle_in(_, s), do: denied(s)

  defp initial?(%{"type" => "hello"}, %{bind: nil, kind: kind}), do: kind in [:control, :browser]

  defp initial?(%{"type" => t}, %{bind: nil, kind: kind})
       when t in ["open_stream", "open_monitor"], do: kind in [:stream, :monitor]

  defp initial?(_, _), do: false

  defp dispatch_text(type, msg, state, raw) when type in ["heartbeat", "probe", "probe_reply"],
    do: sample_request(type, state, fn -> dispatch(type, msg, state, raw) end)

  defp dispatch_text(type, msg, state, raw), do: dispatch(type, msg, state, raw)

  defp dispatch("hello", msg, %{bind: nil, kind: kind} = s, _)
       when kind in [:control, :browser] do
    with true <-
           s.principal.kind != :browser or
             (s.principal.encounter == msg["encounter"] and
                s.principal.acquisition == msg["acquisition"] and s.principal.page == msg["boot"]),
         {:ok, bind} <- S.admit(s.context.db, s.principal, msg) do
      frames = Map.get(msg, "max_credit_frames", 15)
      bytes = Map.get(msg, "max_credit_bytes", 262_144)
      binding = wire_binding(bind)
      next = %{s | bind: bind, binding: binding, frames: frames, bytes: bytes}

      reply(
        "admitted",
        %{
          "api_revision" => 2,
          "lease" => bind.lease,
          "credit_frames" => frames,
          "credit_bytes" => bytes,
          "authority_ms" => bind.authority_ms,
          "phase" => bind.phase,
          "stream_numbers" => %{"audio" => 1, "ecg" => 2, "monitor" => 3}
        },
        next
      )
    else
      _ -> denied(s)
    end
  end

  defp dispatch("open_stream", msg, s, _) when s.kind in [:stream, :browser] do
    with {:ok, bind} <- resolve_bind(s, msg),
         true <- assertions_match?(msg, bind),
         true <- msg["stream"] in ["audio", "ecg"],
         bind = %{bind | connection: S.nonce()},
         {:ok, writer, result} <-
           AcquisitionIngress.open(s.context, bind, msg["stream"], msg["descriptor_ref"]) do
      receipt = result.receipt

      binding =
        Map.merge(wire_binding(bind), %{
          "stream" => msg["stream"],
          "fence" => receipt.fence,
          "journal_id" => receipt.journal_id
        })

      frames = min(s.frames, Map.get(msg, "max_credit_frames", 15))
      bytes = min(s.bytes, Map.get(msg, "max_credit_bytes", 262_144))
      {:ok, ledger} = Credit.new(binding, frames, bytes)

      next = %{
        s
        | bind: bind,
          binding: binding,
          writer: writer,
          receipt: receipt,
          ledger: ledger,
          frames: frames,
          bytes: bytes
      }

      fields = %{
        "receipt" => Receipt.to_map(receipt),
        "credit_frames" => frames,
        "credit_bytes" => bytes
      }

      fields = if result.handoff, do: Map.put(fields, "handoff", result.handoff), else: fields

      if result.terminal,
        do:
          reply(
            "stream_finished",
            Map.merge(fields, %{
              "index_digest" => result.index_digest,
              "terminal" => to_string(result.terminal_kind)
            }),
            %{next | writer: nil}
          ),
        else: reply("durable", fields, next)
    else
      {:error, reason}
      when reason in [:ingress_outcome_unknown, :readmission_required, :effect_in_flight] ->
        recover_connection(s)

      _ ->
        denied(s)
    end
  end

  defp dispatch("open_monitor", msg, %{kind: :monitor} = s, _) do
    with {:ok, bind} <- resolve_bind(s, msg),
         true <- assertions_match?(msg, bind),
         true <- S.current?(s.context.db, bind) do
      bind = %{bind | connection: S.nonce()}

      reply("monitor_credit", %{"credit_frames" => 1, "credit_bytes" => 1968}, %{
        s
        | bind: bind,
          binding: wire_binding(bind)
      })
    else
      _ -> denied(s)
    end
  end

  defp dispatch("gap", msg, %{writer: writer} = s, raw) when is_pid(writer) do
    with true <- msg["operation_id"] == "gap-" <> msg["id"],
         {:ok, sequence} <- Review.counter(msg["next_sequence"]),
         {:ok, sample} <- Review.counter(msg["end"]) do
      fields = Map.take(msg, @gap_keys)

      operation = %{
        id: "gap-" <> msg["id"],
        fingerprint: S.hash(MedEx.CanonicalJSON.encode(fields)),
        bytes: byte_size(raw),
        sequence: sequence,
        sample: sample
      }

      record(s, operation, {:gap, fields})
    else
      _ -> denied(s)
    end
  end

  defp dispatch("checkpoint", _, %{writer: writer} = s, _) when is_pid(writer), do: checkpoint(s)

  defp dispatch("finish", msg, %{writer: writer} = s, _) when is_pid(writer) do
    if Credit.stats(s.ledger).outstanding_frames == 0 do
      case call_writer(
             writer,
             {:finish, msg["sequence"], msg["sample"], msg["interruption"]}
           ) do
        {:ok, %{terminal: true, receipt: receipt, index_digest: digest}} ->
          reply(
            "stream_finished",
            %{
              "receipt" => Receipt.to_map(receipt),
              "index_digest" => digest,
              "terminal" => if(msg["interruption"], do: "interrupted", else: "finished")
            },
            cancel(%{s | writer: nil, receipt: receipt})
          )

        {:error, :outcome_unknown} ->
          recover_connection(s)

        _ ->
          denied(s)
      end
    else
      reply("refused", %{"reason" => "durable_drain_required", "retry" => true}, s)
    end
  end

  defp dispatch(type, msg, s, _) when type in ["finish_acquisition", "collection_finish"] do
    case AcquisitionManifest.finish(s.context, s.bind, Map.take(msg, ["count", "digest"])) do
      {:ok, digest} ->
        MedFabric.Exam.announce(s.bind.encounter, s.context)
        reply("sealed", %{"digest" => digest}, s, :acquisition)

      {:error, :inventory_pending} ->
        reply("inventory_pending", %{}, s)

      _ ->
        denied(s)
    end
  end

  defp dispatch("heartbeat", msg, s, _) do
    with {:ok, status} <- S.heartbeat(s.context.db, s.bind, msg["nonce"]),
         {:ok, command} <- command_poll(s, msg["nonce"]) do
      type = command["type"]

      reply(
        type,
        Map.merge(Map.drop(command, ["type"]), %{
          "stop_requested" => status.stop_requested,
          "remaining_ms" => min(status.remaining_ms, command["remaining_ms"])
        }),
        s
      )
    else
      _ -> denied(s)
    end
  end

  defp dispatch("measurement", msg, %{principal: %{kind: :device}} = s, _) do
    case MeasurementEvents.put(s.context.db, s.bind, msg["event"]) do
      {:ok, result} ->
        Barrier.hit("measurement_commit")
        reply("durable", %{"event_id" => result.event_id, "fingerprint" => result.fingerprint}, s)

      _ ->
        denied(s)
    end
  end

  defp dispatch("result", msg, %{principal: %{kind: :device}} = s, _) do
    result = Map.drop(msg, ["schema", "type", "binding", "operation_id"])

    case DeviceCommands.result(s.context.db, s.bind, result) do
      {:ok, :ok} -> reply("result_saved", %{}, s)
      _ -> denied(s)
    end
  end

  defp dispatch("probe", msg, %{principal: %{kind: :device}} = s, _) do
    id = S.nonce()

    if S.current?(s.context.db, s.bind),
      do:
        reply("probe", %{"id" => id, "stream" => msg["stream"]}, %{
          s
          | probe: {id, msg["stream"], ClockObservations.now()}
        }),
      else: denied(s)
  end

  defp dispatch("probe_reply", msg, %{probe: {id, name, h1}} = s, _) do
    if msg["id"] == id do
      fact = %{
        "stream" => name,
        "h1" => to_string(h1),
        "h4" => to_string(ClockObservations.now()),
        "d2" => msg["d2"],
        "d3" => msg["d3"],
        "host_generation" => ClockObservations.host_generation()
      }

      save_fact(s, "probe", fact)
    else
      denied(s)
    end
  end

  defp dispatch(type, msg, s, _) when type in ["anchor", "status"] do
    if type != "anchor" or
         (s.principal.kind == :device and msg["method"] == "fixture_acquisition_tick"),
       do: save_fact(s, type, Map.drop(msg, ["schema", "type", "binding", "operation_id"])),
       else: denied(s)
  end

  defp dispatch(_, _, s, _), do: denied(s)

  defp command_poll(%{principal: %{kind: :device}} = s, nonce),
    do: DeviceCommands.poll(s.context.db, s.bind, nonce)

  defp command_poll(s, nonce),
    do:
      {:ok,
       %{
         "type" => "heartbeat_reply",
         "nonce" => nonce,
         "boot" => s.bind.boot,
         "generation" => to_string(s.bind.generation),
         "remaining_ms" => 30_000
       }}

  defp save_fact(s, type, body) do
    case S.record_fact(s.context.db, s.bind, type, body) do
      {:ok, :ok} -> reply("recorded", %{}, %{s | probe: nil})
      _ -> denied(s)
    end
  end

  defp record(s, operation, request, payload_bytes \\ 0) do
    digest_field = if match?({:frame, _}, request), do: "transport_sha256", else: "fingerprint"

    case Credit.reserve(s.ledger, s.binding, operation) do
      {:ok, _ledger, :duplicate} ->
        reply(
          "accepted",
          %{"receipt" => Receipt.to_map(s.receipt), digest_field => operation.fingerprint},
          %{s | operation_id: operation.id}
        )

      {:ok, ledger, :new} ->
        stats = Credit.stats(ledger)

        next = %{
          s
          | ledger: ledger,
            operation_id: operation.id,
            max_frame_bytes: max(s.max_frame_bytes, operation.bytes),
            max_payload_bytes: max(s.max_payload_bytes, payload_bytes),
            max_pending_bytes: max(s.max_pending_bytes, stats.outstanding_bytes),
            max_pending_frames: max(s.max_pending_frames, stats.outstanding_frames)
        }

        :telemetry.execute(
          [:mf_exam, :acquisition_ingress, :bounds],
          Map.take(next, [
            :max_frame_bytes,
            :max_payload_bytes,
            :max_pending_bytes,
            :max_pending_frames
          ]),
          %{stream: s.binding["stream"], fence: s.binding["fence"]}
        )

        record_reply(s, next, ledger, operation, request, digest_field)

      _ ->
        denied(s)
    end
  end

  defp checkpoint(s) do
    started = System.monotonic_time(:microsecond)

    case call_writer(s.writer, :checkpoint) do
      {:ok, %{receipt: receipt}} ->
        :telemetry.execute(
          [:mf_exam, :acquisition_ingress, :checkpoint],
          %{duration_us: System.monotonic_time(:microsecond) - started},
          %{stream: s.binding["stream"], fence: s.binding["fence"]}
        )

        durable_reply(cancel(s), receipt)

      {:error, :outcome_unknown} ->
        recover_connection(s)

      _ ->
        denied(s)
    end
  end

  defp durable_reply(s, receipt) do
    with :ok <- Receipt.observe(s.receipt, receipt),
         {:ok, ledger, _} <- Credit.acknowledge(s.ledger, s.binding, receipt) do
      Barrier.hit("durable_before_ack", s.binding["stream"])

      reply("durable", %{"receipt" => Receipt.to_map(receipt)}, %{
        s
        | ledger: ledger,
          receipt: receipt
      })
    else
      _ -> denied(s)
    end
  end

  defp arm(%{flush: nil} = s) do
    token = make_ref()
    delay = if Credit.stats(s.ledger).available_frames == 0, do: 0, else: 250
    %{s | flush: {Process.send_after(self(), {:flush, token}, delay), token}}
  end

  defp arm(s), do: s
  defp cancel(%{flush: nil} = s), do: s

  defp cancel(%{flush: {timer, _}} = s),
    do:
      (
        Process.cancel_timer(timer)
        %{s | flush: nil}
      )

  def handle_info({:flush, token}, %{flush: {_, token}, writer: writer} = s) when is_pid(writer),
    do: checkpoint(%{s | flush: nil, operation_id: "checkpoint-" <> S.nonce()})

  def handle_info(_, s), do: {:ok, s}

  def terminate(_, s) do
    if s.bind && s.binding && s.binding["stream"],
      do:
        DeviceRootLock.invalidate_connection(
          s.context.root_owner,
          {s.bind.id, s.binding["stream"]}
        )

    if s.bind && s.kind in [:control, :browser], do: S.disconnected(s.context.db, s.bind)
    :ok
  end

  defp resolve_bind(%{bind: bind}, _) when is_map(bind), do: {:ok, bind}

  defp resolve_bind(s, %{"binding" => b, "lease" => lease}) do
    with {:ok, generation} <- Review.counter(b["generation"]),
         true <- is_binary(lease) do
      bind = %{
        id: b["acquisition"],
        profile: b["profile"],
        generation: generation,
        connection: b["connection"],
        lease: lease,
        principal: s.principal.id,
        source_kind: s.principal.kind,
        browser_session: Map.get(s.principal, :session)
      }

      S.scoped(s.context.db, bind, fn _, current ->
        Map.merge(bind, %{encounter: current.encounter, boot: current.boot})
      end)
    else
      _ -> {:error, :invalid_binding}
    end
  end

  defp resolve_bind(_, _), do: {:error, :invalid_binding}

  defp assertions_match?(msg, bind),
    do:
      (not Map.has_key?(msg, "acquisition") or msg["acquisition"] == bind.id) and
        (not Map.has_key?(msg, "generation") or msg["generation"] == to_string(bind.generation))

  defp wire_binding(bind),
    do: %{
      "acquisition" => bind.id,
      "profile" => bind.profile,
      "generation" => to_string(bind.generation),
      "connection" => bind.connection
    }

  defp reply(type, fields, s, scope \\ :stream) do
    # This check prevents deliberate submission to a known obsolete binding. A
    # reply already in flight remains historical truth; clients match incarnation.
    # Manifest sealing reacquires retired stream gates while proving quiescence,
    # so its acquisition-scoped reply relies on the current database binding.
    active_stream =
      scope == :acquisition or is_nil(s.binding) or is_nil(s.binding["stream"]) or
        DeviceRootLock.current_connection?(
          s.context.root_owner,
          {s.bind.id, s.binding["stream"]},
          s.binding["connection"]
        )

    if active_stream and
         sample_request(:reply_authority, s, fn -> S.current?(s.context.db, s.bind) end) do
      encode_reply(type, fields, s)
    else
      denied(s)
    end
  end

  defp encode_reply(type, fields, s) do
    fields = Map.merge(fields, %{"binding" => s.binding, "operation_id" => s.operation_id})

    case Control.encode(type, fields) do
      {:ok, bytes} -> {:push, {:text, bytes}, s}
      _ -> denied(s)
    end
  end

  defp sample_request(stage, s, fun) do
    if :erlang.phash2(s.operation_id, 64) == 0 do
      started = System.monotonic_time(:microsecond)
      result = fun.()

      :telemetry.execute(
        [:mf_exam, :acquisition_ingress, :request_timing],
        %{duration_us: System.monotonic_time(:microsecond) - started},
        %{stage: stage, stream: (s.binding && s.binding["stream"]) || "control"}
      )

      result
    else
      fun.()
    end
  end

  defp call_writer(writer, operation) do
    AcquisitionIngress.call(writer, operation)
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp recover_connection(s), do: {:stop, :normal, {1011, "reconcile_required"}, cancel(s)}

  defp denied(s), do: {:stop, :normal, 1008, {:text, "acquisition_request_denied"}, cancel(s)}

  defp monitor_spec(tx, current, frame) do
    unless current.state == "capturing" and current.profile == "paired_exam",
      do: S.abort(tx, :inactive)

    {:ok, spec} = Serialization.stream_spec(current.descriptors["audio"])

    unless frame.source_epoch == spec.source_epoch and frame.sample_count == 960 and
             byte_size(frame.payload) == 1920,
           do: S.abort(tx, :invalid_monitor)

    spec
  end

  defp record_reply(s, next, ledger, operation, request, digest_field) do
    case call_writer(s.writer, request) do
      {:ok, %{receipt: receipt}} ->
        if Receipt.durable?(receipt) do
          durable_reply(next, receipt)
        else
          reply(
            "accepted",
            %{"receipt" => Receipt.to_map(receipt), digest_field => operation.fingerprint},
            arm(next)
          )
        end

      {:error, {:not_committed, _}} ->
        {:ok, ledger} = Credit.refuse(ledger, s.binding, operation.id, operation.fingerprint)

        reply(
          "refused",
          %{
            "reason" => "not_committed",
            digest_field => operation.fingerprint,
            "retry" => true
          },
          %{next | ledger: ledger}
        )

      {:error, :outcome_unknown} ->
        recover_connection(next)

      _ ->
        denied(next)
    end
  end
end
