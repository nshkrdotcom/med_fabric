# The harness owns stdout and aggregates the JSON lines after the Handheld exits.
Application.put_env(:mf_handheld, :spool_timing_observer, fn stream, operation, queue, service ->
  now = System.system_time(:millisecond)

  lines =
    for {phase, us} <- [queue: queue, service: service] do
      row = %{at_ms: now, stream: stream, stage: "spool_#{operation}_#{phase}", duration_us: us}
      [JSON.encode_to_iodata!(row), "\n"]
    end

  IO.binwrite(lines)
end)

MedFabric.Handheld.CLI.main(System.argv())
