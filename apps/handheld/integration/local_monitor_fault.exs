# Run only inside the isolated paired-acceptance device VM.
args = Enum.reject(System.argv(), &(&1 == "--"))
{opts, _, _} = OptionParser.parse(args, strict: [config: :string, scenario: :string])
cfg = opts[:config] |> File.read!() |> JSON.decode!()
session = Task.async(fn -> MedExHandheld.CLI.main(args) end)
receipt = Path.join([cfg["spool_root"], cfg["acquisition"], "audio", "receipt.json"])

durable = fn ->
  with {:ok, data} <- File.read(receipt) do
    JSON.decode!(data)["durable_sample"] |> String.to_integer()
  else
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
    &(:proc_lib.translate_initial_call(&1) == {MedExHandheld.Monitor, :init, 1})
  )

true = is_pid(monitor)

case cfg["local_monitor_fault"] do
  mode when mode in ["stall", "stop"] ->
    :ok = :sys.suspend(monitor)

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

Task.await(session, 120_000)
