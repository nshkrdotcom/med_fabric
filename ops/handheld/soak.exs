defmodule MedFabric.Acceptance.Soak do
  @moduledoc false

  @rates %{"audio" => 48_000, "ecg" => 250}
  @interval_ms 5_000
  @warmup_ms 10_000
  @lag_budget_ms 2_000
  @consecutive_limit 2
  @startup_ms 15_000

  def interval_ms, do: @interval_ms

  def policy do
    %{
      sample_interval_ms: @interval_ms,
      warmup_ms: @warmup_ms,
      lag_budget_ms: @lag_budget_ms,
      consecutive_limit: @consecutive_limit,
      startup_budget_ms: @startup_ms,
      sample_rates_hz: @rates
    }
  end

  def sample(root, seconds, elapsed_ms, previous, children, database) do
    capture_ms =
      if File.regular?(Path.join(root, "source_started.json")) do
        case read_json(Path.join(root, "identity.json")) do
          %{"origin_us" => origin} ->
            max(0, div(System.system_time(:microsecond) - origin, 1_000))

          _ ->
            nil
        end
      end

    rates = if previous, do: previous.streams, else: %{}
    interval = if previous, do: elapsed_ms - previous.elapsed_ms

    streams =
      Map.new(@rates, fn {name, hz} ->
        {name, stream(Path.join(root, name), hz, seconds, capture_ms, rates[name], interval)}
      end)

    %{
      wall_time_ms: System.system_time(:millisecond),
      elapsed_ms: elapsed_ms,
      capture_ms: capture_ms,
      phase: phase(capture_ms, streams),
      streams: streams,
      host_pressure: Map.new(~w(cpu memory io), &{&1, pressure(&1)}),
      filesystem_available_kib: available_kib(root),
      processes: Map.new(children, &{&1.name, process_tree(&1.pid)}),
      postgres: database.()
    }
  end

  defp stream(dir, hz, seconds, capture_ms, previous, interval) do
    source = read_json(Path.join(dir, "source.json"))
    receipt = read_json(Path.join(dir, "ack.json"))["receipt"] || %{}
    durable = String.to_integer(receipt["durable_sample"] || "0")
    produced = max(source["sample"] || 0, durable)
    target = seconds * hz
    expected = min(div((capture_ms || 0) * hz, 1_000), target)

    %{
      target_samples: target,
      expected_samples: expected,
      produced_samples: produced,
      durable_samples: durable,
      capture_lag_ms: lag(expected - produced, hz),
      durable_lag_ms: lag(expected - durable, hz),
      backlog_ms: lag(produced - durable, hz),
      produced_per_s: rate(produced, previous && previous.produced_samples, interval),
      durable_per_s: rate(durable, previous && previous.durable_samples, interval),
      done: source["done"] == true,
      interruption: source["interruption"],
      journal_generation: receipt["journal_generation"]
    }
  end

  defp lag(samples, hz), do: div(max(0, samples) * 1_000, hz)

  defp rate(now, previous, ms) when is_integer(previous) and ms > 0,
    do: div((now - previous) * 1_000, ms)

  defp rate(_, _, _), do: nil

  defp phase(nil, _), do: "starting"

  defp phase(_, streams) do
    cond do
      Enum.any?(streams, fn {_, s} -> !s.done end) -> "capturing"
      Enum.any?(streams, fn {_, s} -> s.produced_samples > s.durable_samples end) -> "draining"
      true -> "sealing"
    end
  end

  def assess(point, streaks) do
    signals =
      for {stream, values} <- Enum.sort(point.streams),
          key <- [:capture_lag_ms, :durable_lag_ms],
          point.capture_ms != nil and point.capture_ms >= @warmup_ms,
          Map.fetch!(values, key) > @lag_budget_ms,
          do: {stream, key}

    streaks = Map.new(signals, &{&1, Map.get(streaks, &1, 0) + 1})

    failures =
      for {{stream, key}, count} <- Enum.sort(streaks), count >= @consecutive_limit do
        %{stream: stream, signal: key, observed_ms: Map.fetch!(point.streams[stream], key)}
      end

    interruptions =
      for {stream, %{interruption: reason}} <- Enum.sort(point.streams),
          is_binary(reason),
          do: %{stream: stream, signal: :source_interrupted, reason: reason}

    startup =
      if point.capture_ms == nil and point.elapsed_ms >= @startup_ms,
        do: [%{signal: :capture_did_not_start, observed_ms: point.elapsed_ms}],
        else: []

    {streaks, startup ++ interruptions ++ failures}
  end

  def print(point) do
    counters =
      Enum.map_join(Enum.sort(point.streams), " · ", fn {name, s} ->
        "#{name}: #{s.produced_per_s || "-"}/#{s.durable_per_s || "-"} samples/s produced/durable" <>
          ", lag #{s.capture_lag_ms}/#{s.durable_lag_ms}ms, backlog #{s.backlog_ms}ms"
      end)

    IO.puts("Soak #{div(point.elapsed_ms, 1_000)}s · #{point.phase} · #{counters}")
  end

  def append!(file, point),
    do: IO.binwrite(file, [JSON.encode_to_iodata!(point), "\n"])

  def observations(path) do
    points = path |> File.stream!() |> Enum.map(&JSON.decode!/1)

    lag_observations =
      Enum.count(points, fn point ->
        point["phase"] != "client_exited" and is_integer(point["capture_ms"]) and
          point["capture_ms"] >= @warmup_ms
      end)

    %{
      sample_count: length(points),
      lag_observations: lag_observations,
      sustained_lag_check_possible: lag_observations >= @consecutive_limit
    }
  end

  def timings(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Stream.flat_map(fn line ->
        case JSON.decode(line) do
          {:ok, %{"stream" => stream, "stage" => stage, "duration_us" => duration}}
          when is_integer(duration) ->
            [{stream, stage, duration}]

          _ ->
            []
        end
      end)
      |> Enum.group_by(fn {stream, stage, _} -> {stream, stage} end, &elem(&1, 2))
      |> Enum.map(fn {{stream, stage}, values} ->
        sorted = Enum.sort(values)

        %{
          stream: stream,
          stage: stage,
          count: length(sorted),
          p50_us: percentile(sorted, 50),
          p95_us: percentile(sorted, 95),
          p99_us: percentile(sorted, 99),
          max_us: List.last(sorted),
          last_10_p50_us: values |> Enum.take(-10) |> Enum.sort() |> percentile(50)
        }
      end)
      |> Enum.sort_by(&{&1.stream, &1.stage})
    else
      []
    end
  end

  defp percentile(sorted, percent),
    do: Enum.at(sorted, div(length(sorted) * percent + 99, 100) - 1)

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, value} when is_map(value) <- JSON.decode(bytes) do
      value
    else
      _ -> %{}
    end
  end

  defp available_kib(root) do
    case System.cmd("timeout", ["2", "df", "-Pk", "--", root], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last()
        |> String.split()
        |> Enum.at(3)
        |> String.to_integer()

      _ ->
        nil
    end
  end

  defp pressure(resource) do
    case File.read("/proc/pressure/#{resource}") do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  defp process_tree(pid) do
    for pid <- descendants(pid),
        record = process(pid),
        record != nil,
        do: record
  end

  defp descendants(pid) do
    case File.read("/proc/#{pid}/task/#{pid}/children") do
      {:ok, children} ->
        [pid | Enum.flat_map(String.split(children), &descendants(String.to_integer(&1)))]

      _ ->
        [pid]
    end
  end

  defp process(pid) do
    dir = "/proc/#{pid}"

    with {:ok, stat} <- File.read(dir <> "/stat") do
      [head, fields] =
        String.split(String.trim(stat), ") ")
        |> Enum.split(-1)
        |> then(fn {head, [last]} -> [Enum.join(head, ") "), String.split(last)] end)

      [_, user_ticks, system_ticks] = Enum.slice(fields, 10, 3)

      %{
        pid: pid,
        name: head |> String.split(" (", parts: 2) |> List.last(),
        start_ticks: String.to_integer(Enum.at(fields, 19)),
        cpu_ticks: String.to_integer(user_ticks) + String.to_integer(system_ticks),
        status: counters(dir <> "/status", ~w(VmRSS RssAnon Threads)),
        io: counters(dir <> "/io", ~w(read_bytes write_bytes)),
        open_fds:
          case File.ls(dir <> "/fd") do
            {:ok, entries} -> length(entries)
            _ -> nil
          end
      }
    else
      _ -> nil
    end
  end

  defp counters(path, keys) do
    case File.read(path) do
      {:ok, contents} ->
        for line <- String.split(contents, "\n"),
            [key, value] <- [String.split(line, ":", parts: 2)],
            key in keys,
            {count, _unit} <- [Integer.parse(String.trim(value))],
            into: %{},
            do: {key, count}

      _ ->
        nil
    end
  end
end
