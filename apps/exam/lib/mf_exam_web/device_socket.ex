defmodule MedFabric.ExamWeb.DeviceSocket do
  @moduledoc "Authenticated independent WSS connections for control, authoritative streams and disposable monitor."
  @behaviour WebSock
  import Plug.Conn
  alias MedEx.Serialization, as: J
  alias MedEx.Wire.{Control, FrameV1}
  alias MedFabric.Domain.DeviceMeasurement
  alias MedFabric.Exam
  alias MedFabric.Exam.{Barrier, ClockObservations, DeviceIngress, DeviceManifest, PreviewGateway}
  alias MedFabric.Store.{DeviceCommands, DeviceSessions, MeasurementEvents, Postgres}

  alias DeviceSessions, as: S

  def init(opts) when is_atom(opts), do: opts
  def init(%{} = state), do: {:ok, state}

  def call(conn, kind) do
    with true <- Exam.lab()[:device_enabled] == true and conn.scheme == :https,
         ["Bearer " <> credential] <- get_req_header(conn, "authorization"),
         {:ok, device} <- S.authenticate(credential) do
      WebSockAdapter.upgrade(
        conn,
        __MODULE__,
        %{
          kind: kind,
          device: device,
          bind: nil,
          writer: nil,
          probe: nil,
          credit: 1,
          in_flight: 0,
          flush_timer: nil
        },
        max_frame_size: 65_584,
        timeout: 65_000
      )
    else
      _ -> send_resp(conn, 403, "Device TLS and enrollment required")
    end
  end

  def handle_in({bytes, [opcode: :text]}, state) when byte_size(bytes) <= 16_384 do
    ops =
      ~w(hello open_stream open_monitor heartbeat result measurement probe probe_reply anchor status collection_finish finish_acquisition gap finish)

    case Control.decode(bytes, ops) do
      {:ok, %{"type" => type} = msg} -> handle(type, msg, state)
      _ -> denied(state)
    end
  rescue
    _ in [ArgumentError, KeyError, FunctionClauseError, MatchError] -> denied(state)
  catch
    :invalid -> denied(state)
  end

  def handle_in(
        {raw, [opcode: :binary]},
        %{kind: :stream, writer: pid, in_flight: in_flight, credit: credit} = s
      )
      when is_pid(pid) and in_flight < credit do
    case DeviceIngress.call(pid, {:frame, raw}) do
      {:ok, r} ->
        accepted = Map.put(J.to_map(r), "transport_sha256", S.hash(raw))
        next_in_flight = in_flight + 1

        next_state =
          if next_in_flight >= credit do
            s = cancel_flush_timer(s)
            send(self(), :checkpoint)
            %{s | in_flight: next_in_flight}
          else
            arm_flush_timer(%{s | in_flight: next_in_flight})
          end

        reply("accepted", accepted, next_state)

      {:durable, r} ->
        Barrier.hit("durable_before_ack", s.stream)
        s = cancel_flush_timer(%{s | in_flight: 0})
        accepted = Map.put(J.to_map(r), "transport_sha256", S.hash(raw))
        push_many([{"accepted", accepted}, {"durable", J.to_map(r)}], s)

      {:capacity, receipt} ->
        stream_finished(receipt, s)

      {:error, {:replay, q, n}} ->
        reply("replay", %{"sequence" => to_string(q), "sample" => to_string(n)}, s)

      _ ->
        denied(s)
    end
  end

  def handle_in({raw, [opcode: :binary]}, %{kind: :monitor, bind: b} = s) when is_map(b) do
    with {:ok, f} <- FrameV1.decode(raw),
         true <- f.stream_number == 3,
         {:ok, :ok} <-
           S.scoped(b, &feed_monitor(&1, &2, b.id, f, raw)) do
      reply("monitor_credit", %{}, s)
    else
      _ -> denied(s)
    end
  end

  def handle_in(_, s), do: denied(s)

  defp feed_monitor(tx, session, id, frame, raw) do
    audio = session.descriptors["audio"]

    unless session.phase == "capturing" and session.profile == "paired_exam" and
             audio["encoding"] == "s16le" and audio["sample_rate"] == ["48000", "1"] and
             length(audio["channels"]) == 1 and frame.sample_count == 960 and
             byte_size(frame.payload) == 1920 and
             to_string(frame.source_epoch) == audio["source_epoch"],
           do: S.abort(tx, :invalid_monitor)

    PreviewGateway.feed(id, raw)
  end

  defp handle(
         "hello",
         %{
           "acquisition" => id,
           "encounter" => enc,
           "profile" => p,
           "boot" => boot,
           "descriptors" => descs
         } = msg,
         %{kind: :control, bind: nil} = s
       ) do
    with true <- Enum.all?([id, enc, boot], &identifier?/1),
         true <- valid_descriptors?(p, descs, id, s.device),
         {:ok, b} <- S.reserve(s.device, enc, id, p, boot, descs) do
      credit = negotiated_credit(msg["max_credit_frames"])

      reply(
        "admitted",
        %{
          "lease" => b.lease,
          "generation" => to_string(b.generation),
          "acquisition" => id,
          "phase" => b.phase,
          "stream_numbers" => %{"audio" => 1, "ecg" => 2, "monitor" => 3},
          "credit_frames" => credit
        },
        %{s | bind: b}
      )
    else
      _ -> denied(s)
    end
  end

  defp handle(
         "open_stream",
         %{
           "acquisition" => id,
           "generation" => g,
           "lease" => lease,
           "stream" => n,
           "descriptor_ref" => digest
         } = msg,
         %{kind: :stream, bind: nil} = s
       ) do
    b = %{id: id, device: s.device, generation: String.to_integer(g), lease: lease}
    credit = negotiated_credit(msg["credit_frames"])

    case DeviceIngress.open(b, n, digest) do
      {:ok, p, r} ->
        reply(
          "durable",
          J.to_map(r),
          Map.merge(s, %{bind: b, writer: p, stream: n, credit: credit, in_flight: 0})
        )

      {:error, {:sealed, r}} ->
        stream_finished(r, %{s | bind: b})

      _ ->
        denied(s)
    end
  end

  defp handle(
         "open_monitor",
         %{"acquisition" => id, "generation" => g, "lease" => lease},
         %{kind: :monitor, bind: nil} = s
       ) do
    b = %{id: id, device: s.device, generation: String.to_integer(g), lease: lease}

    case S.scoped(b, fn _, session ->
           session.profile == "paired_exam" and session.phase == "capturing"
         end) do
      {:ok, true} ->
        reply(
          "monitor_credit",
          %{
            "source_stream" => "audio",
            "transform" => "monitor_gain_v1",
            "domain" => "handheld_monitor"
          },
          %{s | bind: b}
        )

      _ ->
        denied(s)
    end
  end

  defp handle("gap", m, %{kind: :stream, writer: pid, in_flight: in_flight, credit: credit} = s)
       when is_pid(pid) and in_flight < credit do
    case DeviceIngress.call(pid, {:gap, m}) do
      {:durable, r} ->
        Barrier.hit("durable_before_ack", s.stream)
        s = cancel_flush_timer(%{s | in_flight: 0})
        push_many([{"accepted", %{}}, {"durable", J.to_map(r)}], s)

      {:ok, _} ->
        s = cancel_flush_timer(%{s | in_flight: in_flight + 1})
        send(self(), :checkpoint)
        reply("accepted", %{}, s)

      {:capacity, receipt} ->
        stream_finished(receipt, s)

      _ ->
        denied(s)
    end
  end

  defp handle(
         "finish",
         %{"sequence" => q, "sample" => n} = m,
         %{kind: :stream, writer: p, in_flight: 0} = s
       )
       when is_pid(p) do
    case DeviceIngress.call(p, {:finish, q, n, m["interruption"]}) do
      {:ok, r} -> stream_finished(r, s)
      _ -> denied(s)
    end
  end

  defp handle("heartbeat", _, %{kind: :control, bind: b} = s) when is_map(b) do
    with {:ok, :ok} <- S.heartbeat(b), {:ok, msg} <- DeviceCommands.poll(b) do
      action =
        S.rows(
          Postgres,
          "SELECT fact FROM device_facts WHERE acquisition_id=$1 AND kind='operator_stop' LIMIT 1",
          [b.id]
        ) != []

      reply(msg["type"], Map.put(msg, "stop_requested", action), s)
    else
      _ -> denied(s)
    end
  end

  defp handle("result", m, %{kind: :control, bind: b} = s) when is_map(b) do
    case DeviceCommands.result(b, Map.drop(m, ["schema", "type"])) do
      {:ok, :ok} -> reply("result_saved", %{}, s)
      _ -> denied(s)
    end
  end

  defp handle("measurement", %{"event" => e}, %{kind: :control, bind: b} = s) when is_map(b) do
    with :ok <- DeviceMeasurement.validate(e),
         hash = J.digest(e),
         {:ok, r} <- MeasurementEvents.put(b, e, hash) do
      Barrier.hit("measurement_commit")

      reply(
        to_string(r),
        %{
          "event_id" => e["event_id"],
          "fingerprint" => hash,
          "generation" => to_string(b.generation)
        },
        s
      )
    else
      _ -> denied(s)
    end
  end

  defp handle("probe", %{"stream" => n}, %{kind: :control, bind: b} = s)
       when is_map(b) and n in ["audio", "ecg"] do
    case S.scoped(b, fn _, v -> v.phase == "capturing" end) do
      {:ok, true} ->
        id = S.nonce()
        h1 = ClockObservations.now()
        reply("probe", %{"id" => id, "stream" => n}, %{s | probe: {id, n, h1}})

      _ ->
        denied(s)
    end
  end

  defp handle(
         "probe_reply",
         %{"id" => id, "d2" => d2, "d3" => d3},
         %{kind: :control, probe: {id, n, h1}} = s
       ) do
    h4 = ClockObservations.now()

    if number?(d2) and number?(d3) and String.to_integer(d2) <= String.to_integer(d3) do
      fact(s, "probe", %{
        "stream" => n,
        "h1" => to_string(h1),
        "h4" => to_string(h4),
        "d2" => d2,
        "d3" => d3,
        "host_generation" => ClockObservations.host_generation()
      })
    else
      denied(s)
    end
  end

  defp handle(
         "anchor",
         %{
           "stream" => n,
           "method" => "fixture_acquisition_tick",
           "sample_index" => i,
           "tick" => t,
           "error_us" => err
         } = m,
         %{kind: :control, bind: b} = s
       )
       when is_map(b) and n in ["audio", "ecg"] do
    if Enum.all?([i, t, err], &number?/1),
      do: fact(s, "anchor", Map.take(m, ~w(stream method sample_index tick error_us))),
      else: denied(s)
  end

  defp handle("status", %{"state" => v} = m, %{kind: :control, bind: b} = s)
       when is_map(b) and
              v in [
                "acquiring",
                "provisional",
                "repeat",
                "unusable_completed",
                "replaying",
                "interrupted"
              ],
       do: fact(s, "status", Map.take(m, ~w(state event_id repeat_of reason)))

  defp handle(t, m, %{kind: :control, bind: b} = s)
       when t in ["collection_finish", "finish_acquisition"] and is_map(b) do
    case DeviceManifest.finish(b, Map.take(m, ["count", "digest"])) do
      {:ok, digest} ->
        Exam.announce(b.encounter)
        reply("sealed", %{"digest" => digest}, s)

      {:error, :inventory_pending} ->
        reply("inventory_pending", %{}, s)

      _ ->
        denied(s)
    end
  end

  defp handle(_, _, s), do: denied(s)

  defp fact(s, type, body) do
    case S.scoped(s.bind, &record_fact(&1, &2, s.bind.id, type, body)) do
      {:ok, _} -> reply("recorded", %{}, %{s | probe: nil})
      _ -> denied(s)
    end
  end

  defp record_fact(tx, session, id, type, body) do
    if session.phase != "capturing", do: S.abort(tx, :inactive)

    if S.rows(tx, "SELECT count(*) FROM device_facts WHERE acquisition_id=$1", [id]) == [
         [100_000]
       ],
       do: S.abort(tx, :capacity)

    S.fact(tx, id, type, body)
  end

  def handle_info(:flush_batch, %{in_flight: n} = s) when n > 0,
    do: handle_info(:checkpoint, %{s | flush_timer: nil})

  def handle_info(:flush_batch, s), do: {:ok, %{s | flush_timer: nil}}

  def handle_info(:checkpoint, %{writer: pid, in_flight: n} = s) when is_pid(pid) and n > 0 do
    s = cancel_flush_timer(s)
    Barrier.hit("accepted_before_durable", s.stream)

    case DeviceIngress.call(pid, :checkpoint) do
      {:ok, r} ->
        Barrier.hit("durable_before_ack", s.stream)
        reply("durable", J.to_map(r), %{s | in_flight: 0})

      _ ->
        denied(s)
    end
  end

  def handle_info(:checkpoint, s), do: {:ok, s}

  def handle_info(_, s), do: {:ok, s}
  def terminate(_, %{kind: :control, bind: b}) when is_map(b), do: S.disconnected(b)
  def terminate(_, _), do: :ok

  defp stream_finished(receipt, s) do
    s = cancel_flush_timer(s)
    reply("stream_finished", J.to_map(receipt), %{s | writer: nil, in_flight: 0})
  end

  defp negotiated_credit(v) when is_integer(v) and v in 1..15, do: v
  defp negotiated_credit(v) when is_integer(v) and v > 15, do: 15
  defp negotiated_credit(_), do: 1

  defp arm_flush_timer(%{flush_timer: nil} = s),
    do: %{s | flush_timer: Process.send_after(self(), :flush_batch, 250)}

  defp arm_flush_timer(s), do: s

  defp cancel_flush_timer(%{flush_timer: nil} = s), do: s

  defp cancel_flush_timer(%{flush_timer: timer} = s) do
    Process.cancel_timer(timer)
    %{s | flush_timer: nil}
  end

  defp push_many(messages, s) do
    frames =
      Enum.map(messages, fn {t, data} ->
        {:text, Jason.encode!(Map.merge(data, %{"schema" => "medex.device.v1", "type" => t}))}
      end)

    {:push, frames, s}
  end

  defp reply(t, data, s),
    do:
      {:push,
       {:text, Jason.encode!(Map.merge(data, %{"schema" => "medex.device.v1", "type" => t}))}, s}

  defp denied(s), do: {:stop, :normal, 1008, {:text, "device_request_denied"}, s}
  defp number?(s), do: is_binary(s) and Regex.match?(~r/\A(0|[1-9][0-9]{0,18})\z/, s)
  defp identifier?(s), do: is_binary(s) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,96}\z/, s)
  defp valid_descriptors?("plx_spot_check", d, _, _), do: d == %{}

  defp valid_descriptors?("paired_exam", d, id, device) when is_map(d) and map_size(d) == 2 do
    Enum.all?(~w(audio ecg), &valid_descriptor?(d[&1], &1, id, device))
  end

  defp valid_descriptors?(_, _, _, _), do: false

  defp valid_descriptor?(descriptor, stream, id, device) do
    modality = if stream == "audio", do: "medex:diagnostic_audio", else: "medex:ecg"

    case J.stream_spec(descriptor) do
      {:ok, spec} ->
        spec.stream_id == stream and spec.acquisition_id == id and spec.source_ref == device and
          spec.source_epoch == 0 and spec.modality == modality and
          canonical_descriptor?(spec, descriptor)

      _ ->
        false
    end
  end

  defp canonical_descriptor?(spec, data),
    do: spec.descriptor_ref == J.descriptor_ref(spec) and J.to_map(spec) == data
end
