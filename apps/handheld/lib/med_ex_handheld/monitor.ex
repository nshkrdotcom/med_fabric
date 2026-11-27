defmodule MedExHandheld.Monitor do
  @moduledoc "Disposable latest-slot monitor with one atomically admitted control and an exact durable command ledger."
  use GenServer, restart: :temporary
  alias MedEx.{ContractRules, ControlInterlock, Serialization}
  alias MedEx.Wire.{Control, FrameV1}
  alias MedExHandheld.Spool
  @cache_limit 4096
  @result_keys ~w(id fingerprint boot target generation expected_epoch gain status epoch application reason)

  def start_link(opts) do
    case GenServer.start_link(__MODULE__, {self(), opts}) do
      {:error, {:shutdown, reason}} -> {:error, reason}
      result -> result
    end
  end

  def offer(pid, table, batch) when is_pid(pid) and is_list(batch) and length(batch) <= 5 do
    if Process.alive?(pid) and
         Enum.all?(batch, fn
           {q, bytes, next, sample} ->
             is_integer(q) and is_binary(bytes) and byte_size(bytes) <= 65_584 and
               is_integer(next) and is_integer(sample)

           _ ->
             false
         end),
       do: :ets.insert(table, {:batch, System.monotonic_time(:millisecond), batch})

    :ok
  rescue
    ArgumentError -> :ok
  end

  def offer(_, _, _), do: :ok

  def control(pid, table, operation, command, authority) when operation in [:apply, :readback] do
    ticket = make_ref()

    with true <- is_pid(pid) and Process.alive?(pid),
         {:ok, _} <- technical_command(command, authority, System.monotonic_time(:millisecond)),
         true <- :ets.insert_new(table, {:control, ticket, self(), command, authority, operation}) do
      send(pid, {:control, ticket})
      {:ok, ticket}
    else
      false -> {:error, :busy}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def init({caller, opts}) do
    case initialize(opts) do
      {:stop, reason} ->
        Process.unlink(caller)
        {:stop, {:shutdown, reason}}

      success ->
        success
    end
  end

  defp initialize({%{"spool" => root} = config, boot, table})
       when is_binary(root) and is_binary(boot) do
    file = Path.join(root, "monitor.json")

    case load_ledger(file, boot) do
      {:ok, ledger} ->
        timer = Process.send_after(self(), :batch, 20)

        {:ok,
         %{
           file: file,
           ledger: ledger,
           config: config,
           table: table,
           pending: nil,
           timer: timer,
           trace_bytes: trace_size(config),
           drops: 0
         }}

      {:error, _} ->
        {:stop, :invalid_monitor_ledger}
    end
  end

  defp initialize(_), do: {:stop, :invalid_monitor_options}

  def load_ledger(file, boot) do
    case Spool.read_json(file, :missing) do
      :missing -> {:ok, %{"boot" => boot, "epoch" => "0", "gain" => "unity", "cache" => %{}}}
      ledger -> with :ok <- valid_ledger(ledger, boot), do: {:ok, ledger}
    end
  rescue
    _ in [File.Error, JSON.DecodeError, ArgumentError] -> {:error, :invalid_monitor_ledger}
  end

  defp valid_ledger(
         %{"boot" => boot, "epoch" => epoch, "gain" => gain, "cache" => cache} = ledger,
         boot
       )
       when map_size(ledger) == 4 and is_map(cache) and map_size(cache) <= @cache_limit do
    with true <- ContractRules.id?(boot) and gain in ["unity", "half"],
         {:ok, number} <- Control.uint64(epoch),
         true <- number <= 0xFFFFFFFE,
         true <- Enum.all?(cache, fn {id, entry} -> valid_entry?(id, entry, boot, number) end) do
      :ok
    else
      _ -> {:error, :invalid_monitor_ledger}
    end
  end

  defp valid_ledger(_, _), do: {:error, :invalid_monitor_ledger}

  defp valid_entry?(id, %{"command" => command, "result" => result} = entry, boot, actual_epoch)
       when map_size(entry) == 2 and is_map(command) and is_map(result) do
    authority = %{boot: boot, generation: command["generation"], nonce: "ledger", deadline: 1}

    with true <- id == command["id"] and command["boot"] == boot,
         true <-
           Enum.sort(Map.keys(command)) ==
             Enum.sort(~w(id fingerprint boot target generation expected_epoch gain op)),
         {:ok, _} <- technical_command(command, authority, 0),
         true <- Enum.all?(Map.keys(result), &(&1 in @result_keys)),
         true <-
           Map.take(result, ~w(id fingerprint boot target generation expected_epoch gain)) ==
             Map.take(command, ~w(id fingerprint boot target generation expected_epoch gain)),
         true <- result["status"] in ["applied", "rejected", "outcome_unknown"],
         {:ok, epoch} <- Control.uint64(result["epoch"]),
         true <- epoch <= actual_epoch,
         %{"observed_at" => observed, "first_sample" => first} = application <-
           result["application"],
         true <- map_size(application) == 2,
         {:ok, _} <- Control.uint64(observed),
         true <- first == "unknown" or match?({:ok, _}, Control.uint64(first)),
         true <-
           result["reason"] == nil or
             (is_binary(result["reason"]) and byte_size(result["reason"]) <= 96) do
      result["status"] != "applied" or
        (first != "unknown" and epoch == String.to_integer(command["expected_epoch"]) + 1)
    else
      _ -> false
    end
  end

  defp valid_entry?(_, _, _, _), do: false

  def handle_info({:control, ticket}, state) do
    case control_slot(state.table) do
      {:ok, {^ticket, owner, wire, authority, operation}} ->
        process_control(state, ticket, owner, wire, authority, operation)

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:control_expired, ticket}, %{pending: %{ticket: ticket} = pending} = state) do
    if System.monotonic_time(:millisecond) >= pending.authority.deadline,
      do: reject(state, ticket, pending.owner, pending.wire, "expired"),
      else: {:noreply, state}
  end

  def handle_info({:control_expired, _}, state), do: {:noreply, state}

  def handle_info(:batch, state) do
    {batch, captured_at} =
      case take_batch(state.table) do
        {:ok, at, items} -> {items, at}
        :empty -> {[], 0}
      end

    stale? = System.monotonic_time(:millisecond) - captured_at > 200
    state = if stale?, do: %{state | drops: state.drops + length(batch)}, else: state
    batch = if stale?, do: [], else: batch

    {frames, next} =
      Enum.map_reduce(batch, state, fn
        {_, <<"MEX1", _::binary>> = raw, _, _}, acc ->
          case FrameV1.decode(raw) do
            {:ok, %{stream_number: 1} = frame}
            when byte_size(frame.payload) == frame.sample_count * 2 ->
              {pcm, acc} = derive(frame, acc)

              {:ok, encoded} =
                FrameV1.encode(%{
                  frame
                  | stream_number: 3,
                    config_epoch: String.to_integer(acc.ledger["epoch"]),
                    payload: pcm
                })

              {encoded, trace(acc, frame, pcm)}

            _ ->
              {nil, %{acc | drops: acc.drops + 1}}
          end

        _, acc ->
          {nil, acc}
      end)

    valid = Enum.reject(frames, &is_nil/1)
    if valid != [], do: publish(next.table, captured_at, valid)
    {:noreply, %{next | timer: Process.send_after(self(), :batch, 20)}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp derive(frame, %{pending: nil} = state),
    do: {transform(frame.payload, state.ledger["gain"]), state}

  defp derive(frame, state) do
    pending = state.pending
    now = System.monotonic_time(:millisecond)

    decision =
      if current_authority?(state, pending.authority),
        do: technical_command(pending.wire, pending.authority, now),
        else: {:error, :expired}

    case decision do
      {:ok, %{expired: false}} ->
        epoch = String.to_integer(state.ledger["epoch"]) + 1
        pcm = transform(frame.payload, pending.wire["gain"])

        applied =
          result(pending.wire, state, "applied", to_string(frame.first_sample), nil)
          |> Map.put("epoch", to_string(epoch))

        ledger =
          state.ledger
          |> Map.put("epoch", to_string(epoch))
          |> Map.put("gain", pending.wire["gain"])

        next = persist_result(%{state | ledger: ledger}, pending.wire, applied)
        Process.cancel_timer(pending.timer)
        send(pending.owner, {:med_ex_monitor, pending.ticket, applied})
        release(state.table, pending.ticket)
        {pcm, %{next | pending: nil}}

      _ ->
        {:noreply, next} = reject(state, pending.ticket, pending.owner, pending.wire, "expired")
        {transform(frame.payload, next.ledger["gain"]), next}
    end
  end

  defp reject(state, ticket, owner, wire, reason) do
    result = result(wire, state, "rejected", "unknown", reason)

    next =
      if map_size(state.ledger["cache"]) < @cache_limit,
        do: persist_result(state, wire, result),
        else: state

    complete(next, ticket, owner, result)
  end

  defp persist_result(state, command, result) do
    command = Map.take(command, ~w(id fingerprint boot target generation expected_epoch gain op))

    ledger =
      put_in(state.ledger, ["cache", command["id"]], %{"command" => command, "result" => result})

    Spool.write!(state.file, JSON.encode!(ledger))
    %{state | ledger: ledger}
  end

  defp complete(state, ticket, owner, result) do
    if state.pending && state.pending.ticket == ticket,
      do: Process.cancel_timer(state.pending.timer)

    send(owner, {:med_ex_monitor, ticket, result})
    release(state.table, ticket)
    {:noreply, %{state | pending: nil}}
  end

  defp result(command, state, status, first, reason) do
    Map.take(command, ~w(id fingerprint boot target generation expected_epoch gain))
    |> Map.merge(%{
      "status" => status,
      "epoch" => state.ledger["epoch"],
      "application" => %{
        "observed_at" => to_string(System.system_time(:microsecond)),
        "first_sample" => first
      }
    })
    |> then(fn result -> if reason, do: Map.put(result, "reason", reason), else: result end)
  end

  defp internal_result(result) do
    outcome =
      case result["status"] do
        "applied" -> :applied
        "rejected" -> :rejected
        "outcome_unknown" -> :outcome_unknown
      end

    first = result["application"]["first_sample"]

    %{
      id: result["id"],
      fingerprint: result["fingerprint"],
      boot_id: result["boot"],
      target: result["target"],
      generation: String.to_integer(result["generation"]),
      outcome: outcome,
      epoch: String.to_integer(result["epoch"]),
      reason: result["reason"],
      application: %{
        observed_at: String.to_integer(result["application"]["observed_at"]),
        first_sample: if(first == "unknown", do: :unknown, else: String.to_integer(first))
      }
    }
  end

  defp current_authority?(state, authority) do
    expected = authority[:binding]

    case :ets.lookup(state.table, :authority) do
      [{:authority, ^expected, deadline}] when is_map(expected) ->
        System.monotonic_time(:millisecond) < min(deadline, authority.deadline)

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp technical_command(wire, authority, now) when is_map(wire) and is_map(authority) do
    with true <- Enum.all?(~w(id boot target), &ContractRules.id?(wire[&1])),
         true <-
           is_binary(wire["fingerprint"]) and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, wire["fingerprint"]),
         true <-
           wire["target"] == "handheld_monitor" and wire["gain"] in ["unity", "half"] and
             wire["op"] == "set_monitor_gain",
         {:ok, generation} <- Control.uint64(wire["generation"]),
         true <- generation > 0 and generation <= 0x7FFFFFFFFFFFFFFF,
         {:ok, epoch} <- Control.uint64(wire["expected_epoch"]),
         true <- epoch <= 0xFFFFFFFD,
         true <-
           authority[:boot] == wire["boot"] and authority[:generation] == wire["generation"] and
             ContractRules.id?(authority[:nonce]),
         true <- is_integer(authority[:deadline]) do
      {:ok,
       %{
         id: wire["id"],
         fingerprint: wire["fingerprint"],
         boot_id: wire["boot"],
         target: wire["target"],
         generation: generation,
         expected_epoch: epoch,
         value: wire["gain"],
         expired: now >= authority.deadline
       }}
    else
      _ -> {:error, :invalid_command}
    end
  end

  defp technical_command(_, _, _), do: {:error, :invalid_command}

  defp control_slot(table) do
    case :ets.lookup(table, :control) do
      [{:control, ticket, owner, command, authority, operation}] ->
        {:ok, {ticket, owner, command, authority, operation}}

      _ ->
        :empty
    end
  rescue
    ArgumentError -> :empty
  end

  defp release(table, ticket) do
    case :ets.lookup(table, :control) do
      [{:control, ^ticket, _, _, _, _} = item] -> :ets.delete_object(table, item)
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp take_batch(table) do
    case :ets.take(table, :batch) do
      [{:batch, at, items}] -> {:ok, at, items}
      _ -> :empty
    end
  rescue
    ArgumentError -> :empty
  end

  defp publish(table, at, frames) do
    :ets.insert(table, {:latest, make_ref(), at, frames})
  rescue
    ArgumentError -> :ok
  end

  defp trace_size(config) do
    case File.lstat(Path.join(config["spool"], "monitor-truth.jsonl")) do
      {:ok, %{type: :regular, size: size}} -> size
      {:error, :enoent} -> 0
      _ -> 1_048_576
    end
  end

  defp trace(state, frame, pcm) do
    if state.config["trace_monitor"] == true do
      bytes =
        JSON.encode!(%{
          "first" => frame.first_sample,
          "count" => frame.sample_count,
          "epoch" => state.ledger["epoch"],
          "sha256" => Serialization.sha256(pcm)
        }) <> "\n"

      limit =
        case state.config["trace_limit_bytes"] || 1_048_576 do
          value when is_integer(value) and value in 0..1_048_576 -> value
          _ -> 0
        end

      append_trace(state, bytes, limit)
    else
      state
    end
  end

  def transform(bytes, "unity"), do: bytes

  def transform(bytes, "half"),
    do: for(<<v::little-signed-16 <- bytes>>, into: <<>>, do: <<div(v, 2)::little-signed-16>>)

  def terminate(_, state) do
    Process.cancel_timer(state.timer)

    if state.pending do
      Process.cancel_timer(state.pending.timer)
      release(state.table, state.pending.ticket)
    end

    :ok
  end

  defp command_cache(state, wire) do
    case Map.fetch(state.ledger["cache"], wire["id"]) do
      {:ok, entry} ->
        {:ok, technical} =
          technical_command(
            entry["command"],
            %{
              boot: entry["command"]["boot"],
              generation: entry["command"]["generation"],
              nonce: "ledger",
              deadline: 1
            },
            0
          )

        %{
          wire["id"] => %{
            fingerprint: technical.fingerprint,
            command: Map.delete(technical, :expired),
            result: internal_result(entry["result"])
          }
        }

      :error ->
        %{}
    end
  end

  defp schedule_command(state, ticket, owner, wire, authority, now) do
    if current_authority?(state, authority) do
      delay = max(0, authority.deadline - now)
      timer = Process.send_after(self(), {:control_expired, ticket}, delay)

      {:noreply,
       %{
         state
         | pending: %{
             ticket: ticket,
             owner: owner,
             wire: wire,
             authority: authority,
             timer: timer
           }
       }}
    else
      reject(state, ticket, owner, wire, "expired")
    end
  end

  defp decide_command(state, ticket, owner, wire, authority, operation, now, {cache, command}) do
    cache_size = map_size(state.ledger["cache"])

    case ControlInterlock.device_decide(
           cache,
           command,
           String.to_integer(state.ledger["epoch"])
         ) do
      {:cached, _} ->
        complete(state, ticket, owner, state.ledger["cache"][wire["id"]]["result"])

      {:execute_and_persist_result, _}
      when operation == :apply and cache_size < @cache_limit ->
        schedule_command(state, ticket, owner, wire, authority, now)

      decision
      when operation == :readback and decision != {:error, :command_id_conflict} ->
        complete(
          state,
          ticket,
          owner,
          result(wire, state, "outcome_unknown", "unknown", "no_exact_history")
        )

      {:error, :expired} ->
        reject(state, ticket, owner, wire, "expired")

      {:error, :command_id_conflict} ->
        complete(
          state,
          ticket,
          owner,
          result(wire, state, "outcome_unknown", "unknown", "command_conflict")
        )

      _ ->
        reject(state, ticket, owner, wire, "not_applied")
    end
  end

  defp process_control(state, ticket, owner, wire, authority, operation) do
    now = System.monotonic_time(:millisecond)

    case technical_command(wire, authority, now) do
      {:ok, command} ->
        cache = command_cache(state, wire)

        decide_command(state, ticket, owner, wire, authority, operation, now, {cache, command})

      {:error, _} ->
        complete(
          state,
          ticket,
          owner,
          result(wire, state, "rejected", "unknown", "invalid_authority")
        )
    end
  end

  defp append_trace(state, bytes, limit) do
    if state.trace_bytes + byte_size(bytes) <= limit do
      case File.write(Path.join(state.config["spool"], "monitor-truth.jsonl"), bytes, [:append]) do
        :ok -> %{state | trace_bytes: state.trace_bytes + byte_size(bytes)}
        {:error, _} -> %{state | config: Map.put(state.config, "trace_monitor", false)}
      end
    else
      %{state | config: Map.put(state.config, "trace_monitor", false)}
    end
  end
end
