# Run only inside the isolated paired-acceptance device VM.
args = Enum.reject(System.argv(), &(&1 == "--"))
{opts, _, _} = OptionParser.parse(args, strict: [config: :string, scenario: :string])
cfg = opts[:config] |> File.read!() |> JSON.decode!()
root = Path.join(cfg["spool_root"], cfg["acquisition"])

if cfg["local_monitor_fault"] == "startup" do
  File.mkdir_p!(root)

  File.write!(
    Path.join(root, "namespace.json"),
    JSON.encode!(%{"schema" => "mf_handheld.spool", "revision" => 2})
  )

  File.write!(Path.join(root, "monitor.json"), "{")
end

session = Task.async(fn -> MedFabric.Handheld.CLI.main(args) end)
receipt = Path.join([cfg["spool_root"], cfg["acquisition"], "audio", "ack.json"])

durable = fn ->
  case File.read(receipt) do
    {:ok, data} -> JSON.decode!(data)["receipt"]["durable_sample"] |> String.to_integer()
    _ -> 0
  end
end

wait = fn check ->
  Enum.find_value(1..500, fn _ ->
    case check.() do
      false ->
        Process.sleep(20)
        nil

      result ->
        result
    end
  end) || raise "monitor fault condition timed out"
end

before_fault =
  wait.(fn ->
    n = durable.()
    n > 0 && n
  end)

monitor =
  Enum.find(
    Process.list(),
    &(:proc_lib.translate_initial_call(&1) == {MedFabric.Handheld.Monitor, :init, 1})
  )

if cfg["local_monitor_fault"] != "startup", do: true = is_pid(monitor)

case cfg["local_monitor_fault"] do
  mode when mode in ["stall", "stop"] ->
    :ok = :sys.suspend(monitor)

  "startup" ->
    true = is_nil(monitor)

  "kill" ->
    ref = Process.monitor(monitor)
    Process.exit(monitor, :kill)

    receive do
      {:DOWN, ^ref, :process, ^monitor, :killed} -> :ok
    after
      2000 -> raise "monitor survived"
    end
end

after_fault =
  wait.(fn ->
    n = durable.()
    n >= before_fault + 48_000 && n
  end)

if cfg["local_monitor_fault"] in ["stall", "stop"] do
  {:message_queue_len, n} = Process.info(monitor, :message_queue_len)
  true = n <= 3
end

File.write!(
  Path.join([cfg["spool_root"], cfg["acquisition"], "monitor-fault.json"]),
  JSON.encode!(%{before: before_fault, after: after_fault})
)

if cfg["local_monitor_fault"] == "stop" do
  wait.(fn -> File.exists?(Path.join(root, "check-monitor-queue")) end)
  {:message_queue_len, n} = Process.info(monitor, :message_queue_len)
  true = n <= 3
  File.write!(Path.join(root, "monitor-queue-checked"), Integer.to_string(n))
end

Task.await(session, 120_000)
