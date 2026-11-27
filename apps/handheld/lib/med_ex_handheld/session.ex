defmodule MedExHandheld.Application do
  @moduledoc "Starts the supervisor for independently owned Handheld CLI tasks."
  use Application
  def start(_, _), do: Supervisor.start_link([{Task.Supervisor, name: MedExHandheld.Tasks}], strategy: :one_for_one)
end

defmodule MedExHandheld.Session do
  @moduledoc "Device admission, local production and bounded reconnect. Only authenticated host authority enables upload."
  alias MedEx.{ContractRules, Serialization}
  alias MedEx.Wire.Control
  alias MedExHandheld.{Monitor, Paired, PLXAdapter, PLXPeripheral, Spool, Transport}

  @doc "Pure connection and source lifecycle; durable recording truth remains in the spool and host journal."
  def transition(state, event, now) when is_map(state) and is_integer(now) do
    case {state.phase, event} do
      {phase, {:admitted, binding, deadline}} when phase in [:disconnected, :resuming] and deadline > now ->
        {:ok, %{state | phase: if(state.stopped, do: :draining, else: :capturing), binding: binding, authority_deadline: deadline}}
      {phase, :transport_lost} when phase in [:capturing, :draining, :finalizing] ->
        {:ok, %{state | phase: :disconnected, binding: nil, authority_deadline: nil}}
      {:disconnected, :resume} -> {:ok, %{state | phase: :resuming}}
      {:capturing, :source_stopped} -> {:ok, %{state | phase: :draining, stopped: true}}
      {:draining, :durably_drained} -> {:ok, %{state | phase: :finalizing}}
      {:finalizing, {:sealed, digest}} ->
        if ContractRules.digest?(digest), do: {:ok, %{state | phase: :complete}}, else: {:error, :invalid_terminal}
      {phase, :authority_lost} when phase not in [:complete, :interrupted] ->
        {:ok, %{state | phase: :interrupted, binding: nil, authority_deadline: nil, stopped: true}}
      _ -> {:error, :invalid_session_transition}
    end
  end

  def run(config, profile) when profile in ["paired_exam", "plx_spot_check"] do
    :ok = validate_config(config)
    true = MedEx.Contract.api_revision() == 2
    root = Path.join(config["spool_root"], config["acquisition"])
    identity = load_identity(config, profile, root)
    sources = if profile == "paired_exam", do: Paired.sources(identity), else: %{}
    # Before the first local record, the authenticated host must speak this protocol.
    :ok = initial_admission(identity, sources)
    {:ok, resources} = Supervisor.start_link([], strategy: :one_for_one, max_restarts: 0)
    hub = :ets.new(:handheld_session, [:set, :public])
    try do
      execute(identity, sources, resources, hub)
    after
      stop_resources(resources)
      :ets.delete(hub)
    end
  end

  defp validate_config(config) do
    with true <- Enum.all?(~w(acquisition device encounter), &safe_id?(config[&1])),
         root when is_binary(root) <- config["spool_root"], true <- Path.type(root) == :absolute,
         seconds = config["seconds"] || 60, true <- is_integer(seconds) and seconds in 1..1800,
         seed = config["seed"] || 1, true <- is_integer(seed) and seed in 0..0xFFFFFFFF,
         {:ok, _} <- Transport.validate_config(config) do
      :ok
    else
      _ -> raise ArgumentError, "invalid Handheld configuration"
    end
  end

  defp safe_id?(value), do: is_binary(value) and byte_size(value) in 1..96 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp load_identity(config, profile, root) do
    if File.exists?(root) and File.ls!(root) != [] do
      unless Spool.read_json(Path.join(root, "namespace.json"), nil) == %{"schema" => "mf_handheld.spool", "revision" => 2},
        do: raise(ArgumentError, "incompatible spool namespace")
    end
    expected = Map.take(config, ~w(encounter device acquisition)) |> Map.put("profile", profile)
    saved = Spool.read_json(Path.join(root, "identity.json"), nil)
    identity = if saved == nil, do: Map.merge(expected, %{"boot" => Transport.operation_id(), "origin_us" => System.system_time(:microsecond), "api_revision" => 2}), else: saved
    unless is_map(identity) and Map.take(identity, Map.keys(expected)) == expected and
      identity["api_revision"] == 2 and ContractRules.id?(identity["boot"]) and is_integer(identity["origin_us"]),
      do: raise(ArgumentError, "spool identity mismatch")
    config |> Map.put_new("seed", 1) |> Map.merge(identity) |> Map.put("spool", root)
  end

  defp hello(config, sources) do
    Map.merge(Map.take(config, ~w(acquisition encounter profile boot)), %{
      "api_revision" => 2, "descriptors" => Map.new(sources, fn {name, {_, spec}} -> {name, Serialization.to_map(spec)} end),
      "max_credit_frames" => config["max_credit_frames"] || 15,
      "max_credit_bytes" => config["max_credit_bytes"] || 262_144})
  end
  defp initial_admission(config, sources) do
    case Transport.connect(config, "control") do
      {:ok, socket} ->
        try do
          started = System.monotonic_time(:millisecond)
          with {:ok, reply} <- Transport.request(socket, "hello", hello(config, sources)),
               {:ok, _} <- validate_admission(reply, config, started) do
            :ok
          else
            _ -> raise ArgumentError, "Handheld admission refused"
          end
        after
          Transport.close(socket)
        end
      _ -> raise ArgumentError, "Handheld admission unavailable"
    end
  end

  defp execute(config, sources, resources, hub) do
    root = config["spool"]
    {:ok, spool} = Supervisor.start_child(resources, {Spool, root: root, limit: config["spool_limit"] || 67_108_864})
    Spool.write!(Path.join(root, "identity.json"), JSON.encode!(Map.take(config, ~w(encounter device acquisition profile boot origin_us api_revision))))
    for {_, {_, spec}} <- sources, do: :ok = Spool.register(spool, spec)
    monitor = if sources != %{} do
      case Supervisor.start_child(resources, {Monitor, {Map.take(config, ~w(spool trace_monitor trace_limit_bytes)), config["boot"], hub}}) do
        {:ok, pid} -> pid
        {:error, _} -> nil
      end
    end
    {:ok, pool} = Supervisor.start_child(resources, {Task.Supervisor, []})
    marker = Path.join(root, "source_started.json")
    resuming = File.exists?(marker)
    if resuming do
      for {name, {_, spec}} <- sources, do: :ok = Paired.interrupt_after_restart(config, spool, name, spec)
    else
      Spool.write!(marker, JSON.encode!(Map.take(config, ~w(boot acquisition api_revision))))
    end
    config = Map.put(config, "hub", hub)
    tasks = for {name, source} <- sources do
      Task.Supervisor.async(pool, fn -> Paired.produce(config, spool, monitor, hub, name, source) end)
    end
    if config["profile"] == "plx_spot_check", do: collect(config, spool)
    state = %{phase: :disconnected, binding: nil, authority_deadline: nil, stopped: resuming}
    deadline = System.monotonic_time(:millisecond) + min((config["seconds"] || 60) * 1000 + 65_000, 1_800_000)
    outcome = connect(config, sources, spool, monitor, hub, state, deadline)
    :ets.insert(hub, {:stop, true})
    Task.await_many(tasks, 35_000)
    report = %{"acquisition" => config["acquisition"], "status" => if(match?({:ok, _}, outcome), do: "complete", else: "interrupted"),
      "manifest_digest" => case outcome do {:ok, digest} -> digest; _ -> nil end,
      "spool" => Spool.stats(spool)}
    Spool.write!(Path.join(root, "result.json"), JSON.encode!(report))
    report
  end

  defp connect(config, sources, spool, monitor, hub, state, deadline) do
    {:ok, state} = transition(state, :resume, System.monotonic_time(:millisecond))
    result = with {:ok, socket} <- Transport.connect(config, "control") do
      try do
        started = System.monotonic_time(:millisecond)
        with {:ok, reply} <- Transport.request(socket, "hello", hello(config, sources)),
             {:ok, admission} <- validate_admission(reply, config, started),
             {:ok, state} <- transition(state, {:admitted, admission["binding"], admission["authority_deadline"]}, System.monotonic_time(:millisecond)) do
          :ets.insert(hub, {:authority, admission["binding"], admission["authority_deadline"]})
          try do
            case config["profile"] do
              "paired_exam" -> paired(config, socket, spool, monitor, hub, sources, admission, state)
              "plx_spot_check" -> upload_events(config, socket, spool, admission)
            end
          after
            :ets.delete(hub, :authority)
            Spool.invalidate(spool, admission["binding"])
          end
        end
      after
        Transport.close(socket)
      end
    end
    case result do
      {:ok, digest} -> {:ok, digest}
      {:error, :denied} -> :ets.insert(hub, {:stop, true}); {:error, :authority_ended}
      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :ets.insert(hub, {:stop, true})
          {:error, :resume_deadline}
        else
          Process.sleep(250)
          connect(config, sources, spool, monitor, hub, %{state | phase: :disconnected, binding: nil, authority_deadline: nil}, deadline)
        end
    end
  catch
    :exit, _ ->
      :ets.delete(hub, :authority)
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(250)
        connect(config, sources, spool, monitor, hub, %{state | phase: :disconnected, binding: nil, authority_deadline: nil}, deadline)
      else
        {:error, :resume_deadline}
      end
  end

  defp validate_admission(reply, config, started) do
    with %{"type" => "admitted", "binding" => binding, "credit_frames" => frames, "credit_bytes" => bytes, "authority_ms" => duration} <- reply,
         true <- is_map(binding) and Enum.sort(Map.keys(binding)) == Enum.sort(~w(acquisition profile generation connection)),
         true <- binding["acquisition"] == config["acquisition"] and binding["profile"] == config["profile"],
         true <- ContractRules.id?(binding["connection"]), {:ok, generation} <- Control.uint64(binding["generation"]),
         true <- generation in 1..0x7FFFFFFFFFFFFFFF and is_integer(frames) and frames in 1..15,
         true <- is_integer(bytes) and bytes in 1..262_144,
         true <- is_integer(duration) and duration in 1..30_000,
         true <- started + duration > System.monotonic_time(:millisecond),
         true <- is_binary(reply["lease"]) and byte_size(reply["lease"]) in 16..4096 do
      {:ok, Map.put(reply, "authority_deadline", started + duration)}
    else
      _ -> {:error, :invalid_admission}
    end
  end

  defp paired(config, socket, spool, monitor, hub, sources, admission, state) do
    {:ok, uploads} = Task.Supervisor.start_link()
    try do
      tasks = for {name, {_, spec}} <- sources do
        Task.Supervisor.async_nolink(uploads, fn -> Paired.upload(config, spool, admission, name, spec) end)
      end
      if config["preview"] == true, do: Task.Supervisor.start_child(uploads, fn -> monitor_feed(config, admission, hub) end)
      with :ok <- record_anchors(socket, admission["binding"]),
           :ok <- control(config, socket, monitor, hub, tasks, admission, 0),
           {:ok, state} <- if(state.phase == :capturing, do: transition(state, :source_stopped, System.monotonic_time(:millisecond)), else: {:ok, state}),
           {:ok, state} <- transition(state, :durably_drained, System.monotonic_time(:millisecond)),
           {:ok, %{"type" => "sealed", "digest" => digest}} <- request(socket, admission["binding"], "finish_acquisition", %{}, 35_000),
           :ok <- current_control(hub, admission["binding"]),
           {:ok, _} <- transition(state, {:sealed, digest}, System.monotonic_time(:millisecond)) do
        {:ok, digest}
      end
    after
      :ets.delete(hub, :authority)
      Spool.invalidate(spool, admission["binding"])
      Supervisor.stop(uploads)
    end
  end

  defp record_anchors(socket, binding) do
    Enum.reduce_while(["audio", "ecg"], :ok, fn name, :ok ->
      case request(socket, binding, "anchor", %{"stream" => name, "method" => "fixture_acquisition_tick", "sample_index" => "0", "tick" => "8640000", "error_us" => "2"}) do
        {:ok, %{"type" => "recorded"}} -> {:cont, :ok}
        _ -> {:halt, {:error, :anchor_outcome_unknown}}
      end
    end)
  end

  defp current_control(hub, binding) do
    case :ets.lookup(hub, :authority) do
      [{:authority, ^binding, deadline}] -> if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :authority_expired}
      _ -> {:error, :authority_expired}
    end
  end

  defp control(config, socket, monitor, hub, tasks, admission, iteration) do
    {active, error} = Enum.reduce(Task.yield_many(tasks, 0), {[], nil}, fn
      {task, nil}, {active, error} -> {[task | active], error}
      {_, {:ok, :ok}}, acc -> acc
      {_, {:ok, {:error, :denied}}}, {active, _} -> :ets.insert(hub, {:stop, true}); {active, :denied}
      {_, {:ok, {:interrupted, _}}}, {active, _} -> :ets.insert(hub, {:stop, true}); {active, :interrupted}
      _, {active, _} -> {active, :stream_disconnected}
    end)
    cond do
      error != nil -> {:error, error}
      active == [] -> :ok
      true ->
        with :ok <- submit_monitor_results(socket, admission["binding"], 1),
             {:ok, reply, authority} <- poll(socket, admission, config, hub),
             :ok <- monitor_response(reply, authority, monitor, hub) do
          if reply["stop_requested"] == true, do: :ets.insert(hub, {:stop, true})
          if rem(iteration, 5) == 0, do: record_clock_probes(config, socket, admission["binding"])
          Process.sleep(100)
          control(config, socket, monitor, hub, active, admission, iteration + 1)
        end
    end
  end
  defp poll(socket, admission, config, hub) do
    started = System.monotonic_time(:millisecond)
    nonce = Transport.operation_id()
    with {:ok, reply} <- request(socket, admission["binding"], "heartbeat", %{"nonce" => nonce}),
         true <- reply["nonce"] == nonce and reply["generation"] == admission["binding"]["generation"] and reply["boot"] == config["boot"],
         remaining when is_integer(remaining) and remaining in 1..30_000 <- reply["remaining_ms"],
         true <- started + remaining > System.monotonic_time(:millisecond) do
      deadline = started + remaining
      :ets.insert(hub, {:authority, admission["binding"], deadline})
      command_remaining = reply["command_remaining_ms"] || remaining
      if is_integer(command_remaining) and command_remaining in 1..30_000 do
        {:ok, reply, %{nonce: nonce, boot: config["boot"], generation: reply["generation"],
          deadline: min(deadline, started + command_remaining), binding: admission["binding"]}}
      else
        {:error, :invalid_command_authority}
      end
    else
      _ -> :ets.delete(hub, :authority); {:error, :authority_expired}
    end
  end
  defp monitor_response(%{"type" => type, "command" => command}, authority, monitor, hub) when type in ["command", "state_query"] do
    operation = if type == "command", do: :apply, else: :readback
    # Readback may describe exact older command history; it cannot apply an old command.
    authority = if operation == :readback, do: %{authority | generation: command["generation"]}, else: authority
    case Monitor.control(monitor, hub, operation, command, authority) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end
  defp monitor_response(%{"type" => "heartbeat_reply"}, _, _, _), do: :ok
  defp monitor_response(_, _, _, _), do: {:error, :unexpected_heartbeat}
  defp submit_monitor_results(_, _, 0), do: :ok
  defp submit_monitor_results(socket, binding, budget) do
    receive do
      {:med_ex_monitor, _ticket, result} ->
        case request(socket, binding, "result", result) do
          {:ok, %{"type" => "result_saved"}} -> submit_monitor_results(socket, binding, budget - 1)
          _ -> {:error, :command_result_unknown}
        end
    after
      0 -> :ok
    end
  end
  defp record_clock_probes(config, socket, binding) do
    for name <- ["audio", "ecg"] do
      with {:ok, %{"type" => "probe", "id" => id}} <- request(socket, binding, "probe", %{"stream" => name}) do
        d2 = Paired.device_us(config, name)
        request(socket, binding, "probe_reply", %{"id" => id, "d2" => to_string(d2), "d3" => to_string(Paired.device_us(config, name))})
      end
    end
    :ok
  end
  defp request(socket, binding, type, body, timeout \\ 6_000) do
    with {:ok, reply} <- Transport.request(socket, type, Map.put(body, "binding", binding), timeout),
         true <- reply["binding"] == binding do
      {:ok, reply}
    else
      false -> {:error, :stale_binding}
      error -> error
    end
  end

  defp monitor_feed(config, admission, hub) do
    with {:ok, socket} <- Transport.connect(config, "monitor") do
      try do
        with {:ok, %{"type" => "monitor_credit", "binding" => binding}} <- Transport.request(socket, "open_monitor", %{
          "binding" => admission["binding"], "lease" => admission["lease"], "acquisition" => admission["binding"]["acquisition"], "generation" => admission["binding"]["generation"]}) do
          send_latest(socket, binding, admission["binding"], hub, nil)
        end
      after
        Transport.close(socket)
      end
    end
  catch
    :exit, _ -> :ok
  end
  defp send_latest(socket, binding, control_binding, hub, last) do
    if :ets.member(hub, :stop) or current_control(hub, control_binding) != :ok do
      :ok
    else
      case :ets.lookup(hub, :latest) do
        [{:latest, batch_id, at, frames}] when batch_id != last ->
          result = Enum.reduce_while(Enum.with_index(frames), :ok, fn {bytes, index}, _ ->
            now = System.monotonic_time(:millisecond)
            if now - at <= 200 do
              Process.sleep(max(0, at + index * 20 - now))
              with :ok <- current_control(hub, control_binding),
                   :ok <- Transport.send_frame(socket, {:binary, bytes}),
                   {:ok, %{"type" => "monitor_credit", "binding" => ^binding}} <- Transport.recv(socket) do
                {:cont, :ok}
              else
                _ -> {:halt, :failed}
              end
            else
              {:cont, :ok}
            end
          end)
          if result == :ok, do: send_latest(socket, binding, control_binding, hub, batch_id), else: :ok
        _ -> Process.sleep(10); send_latest(socket, binding, control_binding, hub, last)
      end
    end
  rescue
    ArgumentError -> :ok
  end

  defp collect(config, spool) do
    file = Path.join(config["spool"], "inventory.json")
    unless File.exists?(file) do
      peripheral = PLXPeripheral.new() |> PLXPeripheral.subscribe()
      {:ok, _} = PLXAdapter.features(PLXPeripheral.read_features())
      provisional = PLXPeripheral.provisional_notification(peripheral)
      {:ok, %{measurement_status: %{set: [:ongoing]}}} = PLXAdapter.continuous(provisional)
      Spool.write!(Path.join(config["spool"], "provisional.bin"), provisional)
      {peripheral, {:indications, records}} = PLXPeripheral.racp(peripheral, <<1, 1>>)
      {entries, _} = Enum.map_reduce(Enum.with_index(records), nil, fn {raw, sequence}, prior ->
        event = case Spool.get(spool, "events", sequence) do
          {:ok, bytes} -> JSON.decode!(bytes)
          :absent ->
            event = PLXPeripheral.event(raw, Transport.operation_id(), sequence, prior, config, :fixed_fixture_utc)
            :ok = Spool.put(spool, "events", sequence, MedEx.CanonicalJSON.encode(event))
            event
        end
        {[event["event_id"], Serialization.digest(event)], event["event_id"]}
      end)
      {_, <<6, 0, 1, 1>>} = PLXPeripheral.complete(peripheral)
      Spool.write!(file, JSON.encode!(entries))
    end
  end
  defp upload_events(config, socket, spool, admission) do
    binding = admission["binding"]
    inventory = Spool.read_json(Path.join(config["spool"], "inventory.json"), [])
    with :ok <- Spool.event_activate(spool, binding),
         :ok <- if(admission["phase"] == "sealed", do: :ok, else: transfer_events(config, socket, spool, binding, inventory)),
         {:ok, %{"type" => "sealed", "digest" => digest}} <- request(socket, binding, "collection_finish", %{
           "count" => to_string(length(inventory)), "digest" => Serialization.digest(inventory)}, 35_000),
         :ok <- current_control(config["hub"], binding),
         true <- ContractRules.digest?(digest),
         :ok <- Spool.event_seal(spool, binding, inventory) do
      {:ok, digest}
    else
      false -> {:error, :invalid_manifest_digest}
      {:error, _} = error -> error
      _ -> {:error, :unexpected_collection_reply}
    end
  end

  defp transfer_events(config, socket, spool, binding, inventory) do
    Enum.reduce_while(Enum.with_index(inventory), :ok, fn {[id, expected], sequence}, :ok ->
      with :ok <- current_control(config["hub"], binding),
           {:ok, bytes} <- Spool.get(spool, "events", sequence),
           {:ok, %{"type" => "durable", "event_id" => ^id, "fingerprint" => ^expected}} <-
             request(socket, binding, "measurement", %{"event" => JSON.decode!(bytes)}),
           :ok <- current_control(config["hub"], binding),
           :ok <- Spool.event_ack(spool, binding, sequence, id, expected) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :event_outcome_unknown}}
      end
    end)
  end

  @doc false
  def stop_resources(resources) do
    if Process.alive?(resources) do
      for {_, pool, _, modules} <- Supervisor.which_children(resources), is_pid(pool), modules == [Task.Supervisor],
          producer <- Task.Supervisor.children(pool), do: Process.unlink(producer)
      Supervisor.stop(resources)
    end
  end
end

defmodule MedExHandheld.CLI do
  @moduledoc "Run a configured synthetic/reference paired or PLX acquisition."
  def main(args) do
    {options, _, []} = OptionParser.parse(Enum.reject(args, &(&1 == "--")), strict: [config: :string, scenario: :string])
    config = File.read!(Keyword.fetch!(options, :config)) |> JSON.decode!()
    task = Task.Supervisor.async_nolink(MedExHandheld.Tasks, fn ->
      MedExHandheld.Session.run(config, Keyword.fetch!(options, :scenario))
    end)
    case Task.await(task, :infinity) do
      %{"status" => "complete"} -> IO.puts("Synthetic acquisition sealed")
      %{"status" => "interrupted"} -> IO.puts(:stderr, "Acquisition interrupted; retained source requires reconciliation"); System.halt(1)
    end
  end
end
