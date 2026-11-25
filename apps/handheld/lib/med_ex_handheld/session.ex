defmodule MedExHandheld.Application do
  @moduledoc "Starts the supervisor for Handheld CLI tasks."
  use Application

  def start(_, _),
    do:
      Supervisor.start_link([{Task.Supervisor, name: MedExHandheld.Tasks}],
        strategy: :one_for_one
      )
end

defmodule MedExHandheld.Session do
  @moduledoc "Standalone producer. Source capture persists through upload disconnects and reauthentication."
  alias MedEx.Serialization, as: J
  alias MedExHandheld.{Monitor, Paired, PLXAdapter, PLXPeripheral, Spool, Transport}

  def run(config, profile) when profile in ["paired_exam", "plx_spot_check"] do
    for key <- ~w(acquisition device encounter) do
      unless is_binary(config[key]) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,96}\z/, config[key]),
        do: raise("invalid device configuration identity")
    end

    root = Path.join(config["spool_root"], config["acquisition"])
    File.mkdir_p!(root)
    {:ok, resources} = Supervisor.start_link([], strategy: :one_for_one, max_restarts: 0)

    try do
      collect_session(config, profile, root, resources)
    after
      stop_resources(resources)
    end
  end

  @doc false
  def stop_resources(resources) do
    # Fail fast on abnormal source exits during capture. Shutdown is intentional:
    # detach even a producer started just before its sibling failed to start.
    for {Task.Supervisor, pool, _, _} <- Supervisor.which_children(resources),
        is_pid(pool),
        producer <- Task.Supervisor.children(pool) do
      Process.unlink(producer)
    end

    Supervisor.stop(resources)
  end

  defp collect_session(config, profile, root, resources) do
    {:ok, spool} =
      Supervisor.start_child(
        resources,
        {Spool, [root: root, limit: config["spool_limit"] || 67_108_864]}
      )

    c = load_identity(config, profile, root)
    {:ok, monitor} = Supervisor.start_child(resources, {Monitor, {root, c["boot"]}})
    {:ok, hub} = Supervisor.start_child(resources, {Agent, fn -> %{latest: nil, stop: false} end})
    # Stop producers before closing their monitor and durable spool.
    {:ok, producers} = Supervisor.start_child(resources, {Task.Supervisor, []})
    sources = if profile == "paired_exam", do: Paired.sources(c), else: %{}
    marker = Path.join(root, "source_started.json")
    resuming = File.exists?(marker)

    c = prepare_source(c, sources, marker, resuming)

    tasks = start_producers(c, spool, monitor, hub, producers, sources, resuming)
    if profile == "plx_spot_check", do: collect_spot_check(c, spool, resuming)

    digest =
      connect(
        c,
        spool,
        monitor,
        hub,
        sources,
        System.monotonic_time(:second) + min((c["seconds"] || 60) + 65, 1800)
      )

    if profile == "plx_spot_check" do
      entries = Spool.read_json(Path.join(c["spool"], "inventory.json"), [])
      :ok = GenServer.call(spool, {:event_seal, entries})
    end

    Task.await_many(tasks, 10_000)

    report = %{
      "acquisition" => c["acquisition"],
      "manifest_digest" => digest,
      "spool" => Spool.stats(spool)
    }

    Spool.write!(Path.join(root, "result.json"), JSON.encode!(report))
    report
  end

  defp load_identity(config, profile, root) do
    marker = Path.join(root, "identity.json")

    identity =
      Spool.read_json(marker, %{
        "encounter" => config["encounter"],
        "boot" => Base.url_encode64(:crypto.strong_rand_bytes(18)),
        "origin_us" => System.system_time(:microsecond),
        "device" => config["device"],
        "profile" => profile,
        "acquisition" => config["acquisition"]
      })

    if identity["profile"] != profile or identity["device"] != config["device"] or
         identity["encounter"] != config["encounter"] or
         identity["acquisition"] != config["acquisition"] do
      raise "spool identity mismatch"
    end

    Spool.write!(marker, JSON.encode!(identity))
    config |> Map.merge(identity) |> Map.put("spool", root)
  end

  defp prepare_source(c, _sources, _marker, true), do: c

  defp prepare_source(c, sources, marker, false) do
    # A new collection must receive an authenticated grant and accept its descriptors.
    initial_admission!(c, sources)
    c = Map.put(c, "origin_us", System.system_time(:microsecond))

    Spool.write!(
      Path.join(c["spool"], "identity.json"),
      JSON.encode!(Map.take(c, ~w(encounter boot origin_us device profile acquisition)))
    )

    Spool.write!(
      marker,
      JSON.encode!(%{"boot" => c["boot"], "acquisition" => c["acquisition"]})
    )

    c
  end

  defp start_producers(c, spool, monitor, hub, producers, sources, resuming) do
    if resuming do
      for {n, {_, spec}} <- sources, do: Paired.interrupt_after_restart(c, spool, n, spec)
    end

    for {name, source} <- sources do
      Task.Supervisor.async(producers, fn ->
        Paired.produce(c, spool, monitor, hub, name, source)
      end)
    end
  end

  defp collect_spot_check(c, spool, resuming) do
    collect(c, spool)

    if c["hold_after_ingestion"] == true and not resuming,
      do: wait_for_release(c["spool"], System.monotonic_time(:second) + 45)
  end

  defp wait_for_release(root, deadline) do
    unless File.exists?(Path.join(root, "release-upload")) do
      if System.monotonic_time(:second) > deadline, do: raise("test ingestion barrier expired")
      Process.sleep(25)
      wait_for_release(root, deadline)
    end
  end

  defp hello(c, sources) do
    desc = Map.new(sources, fn {n, {_, spec}} -> {n, J.to_map(spec)} end)
    Map.merge(Map.take(c, ~w(acquisition encounter profile boot)), %{"descriptors" => desc})
  end

  defp initial_admission!(c, sources) do
    case Transport.connect(c, "control") do
      {:ok, s} ->
        try do
          case Transport.request(s, "hello", hello(c, sources)) do
            {:ok, %{"type" => "admitted", "phase" => "capturing", "credit_frames" => 1}} ->
              :ok

            {:error, :denied} ->
              raise "Admission refused by Exam for #{c["profile"]} (#{c["device"]}). Check the device, encounter, and active clinician authorization in /encounters/#{c["encounter"]}/devices."

            other ->
              raise "Unexpected Exam admission response for #{c["profile"]} (#{c["device"]}): #{inspect(other)}"
          end
        after
          Transport.close(s)
        end

      {:error, reason} ->
        raise "Could not connect to Exam control socket (#{c["server"]}): #{inspect(reason)}"
    end
  end

  defp connect(c, spool, monitor, hub, sources, deadline) do
    result =
      try do
        with {:ok, s} <- Transport.connect(c, "control") do
          try do
            {:ok, %{"type" => "admitted"} = admit} =
              Transport.request(s, "hello", hello(c, sources))

            bind = Map.take(admit, ~w(lease acquisition generation))

            result =
              cond do
                admit["phase"] == "sealed" -> finish(c, s)
                c["profile"] == "plx_spot_check" -> upload_events(c, s, spool, admit["phase"])
                true -> paired(c, s, spool, monitor, hub, sources, bind)
              end

            {:ok, result}
          after
            Transport.close(s)
          end
        end
      rescue
        e in [MatchError, CaseClauseError] ->
          {:error, Exception.message(e) |> String.slice(0, 100)}
      catch
        :exit, _ -> {:error, :connection_lost}
      end

    case result do
      {:ok, digest} ->
        digest

      {:error, _} ->
        if System.monotonic_time(:second) >= deadline,
          do: raise("resume deadline exceeded with spool retained")

        Process.sleep(250)
        connect(c, spool, monitor, hub, sources, deadline)
    end
  end

  defp paired(c, s, spool, monitor, hub, sources, bind) do
    {:ok, uploads} = Task.Supervisor.start_link()

    try do
      tasks =
        for {name, {_, spec}} <- sources do
          Task.Supervisor.async_nolink(uploads, fn ->
            Paired.upload(c, spool, bind, name, spec)
          end)
        end

      if c["preview"] do
        {:ok, _} = Task.Supervisor.start_child(uploads, fn -> monitor_feed(c, bind, hub) end)
      end

      for n <- ["audio", "ecg"] do
        {:ok, %{"type" => "recorded"}} =
          Transport.request(s, "anchor", %{
            "stream" => n,
            "method" => "fixture_acquisition_tick",
            "sample_index" => "0",
            "tick" => "8640000",
            "error_us" => "2"
          })
      end

      control(c, s, monitor, hub, tasks, 0)
      finish(c, s)
    after
      Supervisor.stop(uploads)
    end
  end

  defp control(c, s, monitor, hub, tasks, iteration) do
    {active, loss} =
      Enum.reduce(Task.yield_many(tasks, 0), {[], false}, fn
        {t, nil}, {list, lost} -> {[t | list], lost}
        {_, {:ok, :ok}}, acc -> acc
        _, {list, _} -> {list, true}
      end)

    if loss, do: raise(MatchError, term: :stream_disconnected)

    if active != [] do
      {:ok, reply} = Transport.request(s, "heartbeat")
      if reply["stop_requested"], do: Agent.update(hub, &Map.put(&1, :stop, true))

      case reply["type"] do
        "command" -> apply_monitor_command(reply, c, s, monitor)
        "state_query" -> reconcile_monitor_state(reply, s, monitor)
        "heartbeat" -> :ok
      end

      if rem(iteration, 5) == 0 do
        record_clock_probes(c, s)
      end

      Process.sleep(100)
      control(c, s, monitor, hub, active, iteration + 1)
    end
  end

  defp record_clock_probes(c, s) do
    for n <- ["audio", "ecg"] do
      {:ok, %{"type" => "probe", "id" => id}} =
        Transport.request(s, "probe", %{"stream" => n})

      d2 = Paired.device_us(c, n)

      {:ok, %{"type" => "recorded"}} =
        Transport.request(s, "probe_reply", %{
          "id" => id,
          "d2" => to_string(d2),
          "d3" => to_string(Paired.device_us(c, n))
        })
    end
  end

  defp apply_monitor_command(reply, c, s, monitor) do
    case GenServer.call(monitor, {:command, reply}) do
      {:result, result} -> Transport.request(s, "result", result)
      _ -> :ok
    end

    if !c["lose_command_ack"] do
      Process.sleep(25)
      state = GenServer.call(monitor, {:state, reply})
      if state["status"] == "applied", do: Transport.request(s, "result", state)
    end
  end

  defp reconcile_monitor_state(reply, s, monitor) do
    state = GenServer.call(monitor, {:state, reply})
    if state["status"] != "pending", do: Transport.request(s, "result", state)
  end

  defp monitor_feed(c, bind, hub) do
    with {:ok, s} <- Transport.connect(c, "monitor") do
      try do
        {:ok, %{"type" => "monitor_credit"}} = Transport.request(s, "open_monitor", bind)
        send_latest(s, hub, nil)
      after
        Transport.close(s)
      end
    end
  end

  defp send_latest(s, hub, last) do
    case Agent.get(hub, & &1.latest) do
      {at, bytes} when at != last ->
        if System.monotonic_time(:millisecond) - at <= 200 do
          :ok = Transport.send_frame(s, {:binary, bytes})
          {:ok, %{"type" => "monitor_credit"}} = Transport.recv(s)
        end

        send_latest(s, hub, at)

      _ ->
        Process.sleep(10)
        send_latest(s, hub, last)
    end
  end

  defp collect(c, spool) do
    file = Path.join(c["spool"], "inventory.json")

    unless File.exists?(file) do
      p = PLXPeripheral.new() |> PLXPeripheral.subscribe()
      %{features: 0x2A60} = PLXPeripheral.discover()
      {:ok, _} = PLXAdapter.features(PLXPeripheral.read_features())
      provisional = PLXPeripheral.provisional_notification(p)
      {:ok, %{measurement_status: %{set: [:ongoing]}}} = PLXAdapter.continuous(provisional)
      Spool.write!(Path.join(c["spool"], "provisional.bin"), provisional)
      {_, <<5, 0, 2::little-16>>} = PLXPeripheral.racp(p, <<4, 1>>)
      {p, {:indications, records}} = PLXPeripheral.racp(p, <<1, 1>>)

      {entries, _} =
        Enum.map_reduce(Enum.with_index(records), nil, fn {raw, i}, prior ->
          event = collect_event(c, spool, raw, i, prior)
          {[event["event_id"], J.digest(event)], event["event_id"]}
        end)

      {_, <<6, 0, 1, 1>>} = PLXPeripheral.complete(p)
      Spool.write!(file, JSON.encode!(entries))
    end
  end

  defp collect_event(c, spool, raw, sequence, prior) do
    case Spool.get(spool, "events", sequence) do
      {:ok, bytes} ->
        JSON.decode!(bytes)

      :absent ->
        event =
          PLXPeripheral.event(
            raw,
            Base.url_encode64(:crypto.strong_rand_bytes(18)),
            sequence,
            prior,
            :fixed_fixture_utc
          )

        :ok = PLXPeripheral.validate_sdk(event, c)
        :ok = Spool.put(spool, "events", sequence, JSON.encode!(event))
        event
    end
  end

  defp upload_events(c, s, spool, phase) do
    inventory = Spool.read_json(Path.join(c["spool"], "inventory.json"), [])

    if phase == "capturing" do
      for state <- ["acquiring", "provisional", "unusable_completed", "repeat"] do
        {:ok, %{"type" => "recorded"}} =
          Transport.request(s, "status", %{"state" => state, "repeat_of" => hd(hd(inventory))})
      end
    end

    if c["offline_finish"] do
      {:ok, %{"type" => state}} =
        Transport.request(s, "collection_finish", %{
          "count" => to_string(length(inventory)),
          "digest" => J.digest(inventory)
        })

      true = state in ["inventory_pending", "sealed"]
    end

    for {[id, expected], i} <- Enum.with_index(inventory) do
      {:ok, bytes} = Spool.get(spool, "events", i)
      ev = JSON.decode!(bytes)

      {:ok, %{"type" => "durable", "event_id" => ^id, "fingerprint" => ^expected}} =
        Transport.request(s, "measurement", %{"event" => ev})

      :ok = GenServer.call(spool, {:event_ack, i, id, expected})
    end

    finish(c, s)
  end

  defp finish(%{"profile" => "paired_exam"}, s) do
    {:ok, %{"type" => "sealed", "digest" => d}} = Transport.request(s, "finish_acquisition")
    d
  end

  defp finish(c, s) do
    inv = Spool.read_json(Path.join(c["spool"], "inventory.json"), [])

    {:ok, %{"type" => "sealed", "digest" => d}} =
      Transport.request(s, "collection_finish", %{
        "count" => to_string(length(inv)),
        "digest" => J.digest(inv)
      })

    d
  end
end

defmodule MedExHandheld.CLI do
  @moduledoc "Command-line entry point for Handheld acquisition sessions."
  def main(args) do
    {opt, _, []} =
      OptionParser.parse(Enum.reject(args, &(&1 == "--")),
        strict: [config: :string, scenario: :string]
      )

    cfg = File.read!(Keyword.fetch!(opt, :config)) |> JSON.decode!()
    scenario = Keyword.fetch!(opt, :scenario)

    task =
      Task.Supervisor.async_nolink(MedExHandheld.Tasks, fn ->
        try do
          {:ok, MedExHandheld.Session.run(cfg, scenario)}
        rescue
          e in RuntimeError -> {:error, Exception.message(e)}
        end
      end)

    case Task.await(task, :infinity) do
      {:ok, _} ->
        IO.puts("Synthetic acquisition sealed")

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}")
        System.halt(1)
    end
  end
end
