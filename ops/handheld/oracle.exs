defmodule MedFabric.Acceptance.Oracle do
  @moduledoc false
  # Independent fixture math: deliberately does not load MedEx, application
  # modules, stream decoders, clock fitters, or production sample generators.
  def sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  def read(path), do: path |> File.read!() |> JSON.decode!()
  def check!(true, _message), do: :ok
  def check!(_other, message), do: raise(message)

  def verify!(directory, cfg, root, manifest) do
    checks =
      for {name, stream} <- manifest["streams"], into: %{} do
        {name, stream!(directory, cfg, root, name, stream)}
      end

    check!(Map.keys(checks) |> Enum.sort() == ["audio", "ecg"], "Missing waveform stream")

    %{
      raw_payload_digests: Map.new(checks, fn {name, value} -> {name, value.raw} end),
      oracle_payload_digests: Map.new(checks, fn {name, value} -> {name, value.expected} end),
      coverage: Map.new(checks, fn {name, value} -> {name, value.coverage} end),
      clock_holdouts: Map.new(checks, fn {name, value} -> {name, value.clock} end),
      duplicate_logical_frames: 0
    }
  end

  defp stream!(directory, cfg, root, name, stream) do
    index = stream["index"]
    desc = index["stream"]
    width = Map.fetch!(%{"s16le" => 2, "s24le" => 3, "s32le" => 4}, desc["encoding"])
    channels = length(desc["channels"])
    source = if name == "audio", do: 1, else: 2

    {spans, raw} =
      Enum.map_reduce(index["segments"], :crypto.hash_init(:sha256), fn seg, hash ->
        first = integer(seg["first_sample"])
        last = integer(seg["end_sample"])
        # Fixture manifest segment keys are relative filenames; refuse traversal.
        key = seg["key"]

        check!(
          is_binary(key) and Path.type(key) == :relative and
            not String.contains?(key, ["\\", <<0>>]) and
            Enum.all?(String.split(key, "/"), &(&1 not in ["", ".", ".."])),
          "Invalid segment key"
        )

        bytes = File.read!(Path.join([root, name, index["fence"], key]))

        check!(
          sha(bytes) == seg["sha256"] and byte_size(bytes) == (last - first) * channels * width,
          "Segment integrity or sample length differs"
        )

        {{first, last}, :crypto.hash_update(hash, bytes)}
      end)

    gaps =
      for span <- index["spans"],
          span["code"] == "source_gap",
          do: {integer(span["first_sample"]), integer(span["end_sample"])}

    expected_gaps =
      case {name, cfg["gap"]} do
        {"audio", true} ->
          [{1920, 2020}]

        {"audio", 3} ->
          assert_gap_sequences!(index)
          [{1920, 2220}]

        _ ->
          []
      end

    check!(gaps == expected_gaps, "Unexpected source gaps for #{name}")

    edge =
      Enum.reduce(Enum.sort(spans ++ gaps), 0, fn {first, last}, edge ->
        check!(first == edge and last > first, "Duplicate, overlap, or undeclared gap in #{name}")
        last
      end)

    [num, den] = Enum.map(desc["sample_rate"], &integer/1)

    cond do
      cfg["restart_cutoffs"] ->
        check!(edge == cfg["restart_cutoffs"][name], "Restart cutoff differs")

      (cfg["spool_limit"] || 67_108_864) < 67_108_864 || cfg["reset"] ->
        :ok

      true ->
        check!(edge == div(cfg["seconds"] * num, den), "Wrong sample count for #{name}")
    end

    raw = hash_hex(raw)

    expected =
      0..(edge - 1)//65_536
      |> Enum.reduce(:crypto.hash_init(:sha256), fn first, hash ->
        pcm =
          samples(
            first,
            min(first + 65_536, edge),
            channels,
            width,
            cfg["seed"],
            source,
            expected_gaps,
            1
          )

        :crypto.hash_update(hash, pcm)
      end)
      |> hash_hex()

    check!(raw == expected, "Independent raw sample hash differs for #{name}")
    clock = clock!(directory, cfg, stream, name, edge, num, den)
    check!(clock.violations == 0, "Clock holdout outside interval for #{name}")

    %{
      raw: raw,
      expected: expected,
      coverage: %{
        spans: Enum.map(spans, &Tuple.to_list/1),
        gaps: Enum.map(gaps, &Tuple.to_list/1),
        samples: edge,
        index_digest: stream["digest"]
      },
      clock: clock
    }
  end

  defp hash_hex(hash), do: hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

  defp assert_gap_sequences!(index) do
    check!(
      Enum.map(index["gaps"], &{&1["first_sequence"], &1["next_sequence"]}) == [{"2", "5"}],
      "Multi-record gap sequence coverage differs"
    )
  end

  def samples(first, last, channels, width, seed, source, gaps, divisor) do
    for i <- first..(last - 1)//1,
        i < last,
        not Enum.any?(gaps, fn {a, b} -> i >= a and i < b end),
        ch <- 1..channels,
        into: <<>> do
      value = div(rem(i * 37 + seed * 17 + ch * 13 + source * 101, 65_536) - 32_768, divisor)
      <<value::little-signed-size(width * 8)>>
    end
  end

  def monitor!(directory, cfg, manifest) do
    root = Path.join([directory, "spool", cfg["acquisition"]])
    monitor = read(Path.join(root, "monitor.json"))
    [mutation] = Map.values(monitor["cache"])

    check!(
      monitor["epoch"] == "1" and monitor["gain"] == "half" and
        Enum.any?(manifest["facts"], fn fact ->
          fact["type"] == "command_applied" and fact["body"] == mutation["result"]
        end),
      "Committed monitor command differs from the exact persisted result"
    )

    changed = integer(mutation["result"]["application"]["first_sample"])

    {count, raw, expected} =
      File.stream!(Path.join(root, "monitor-truth.jsonl"))
      |> Enum.reduce({0, :crypto.hash_init(:sha256), :crypto.hash_init(:sha256)}, fn line,
                                                                                     {edge, raw,
                                                                                      expected} ->
        record = JSON.decode!(line)
        first = record["first"]
        count = record["count"]
        check!(first == edge and count > 0, "Monitor trace missing or duplicated samples")
        divisor = if first >= changed, do: 2, else: 1
        pcm = samples(first, first + count, 1, 2, cfg["seed"], 1, [], divisor)
        expected_digest = sha(pcm)
        check!(record["sha256"] == expected_digest, "Monitor sample digest differs")

        {edge + count, :crypto.hash_update(raw, Base.decode16!(record["sha256"], case: :mixed)),
         :crypto.hash_update(expected, Base.decode16!(expected_digest, case: :mixed))}
      end)

    check!(count == cfg["seconds"] * 48_000, "Incomplete monitor trace")

    %{
      command_mutations: 1,
      monitor_checked_samples: count,
      monitor_trace_digest: Base.encode16(:crypto.hash_final(raw), case: :lower),
      monitor_oracle_trace_digest: Base.encode16(:crypto.hash_final(expected), case: :lower)
    }
  end

  # Exact rational interval evaluation, not the production clock estimator.
  defp fraction([n, d]), do: ratio(integer(n), integer(d))
  defp fraction(v), do: {integer(v), 1}

  defp ratio(n, d) when d > 0 do
    g = Integer.gcd(abs(n), d)
    {div(n, g), div(d, g)}
  end

  defp add({a, b}, {c, d}), do: ratio(a * d + c * b, b * d)
  defp sub(a, {c, d}), do: add(a, {-c, d})
  defp mul({a, b}, {c, d}), do: ratio(a * c, b * d)
  defp le?({a, b}, {c, d}), do: a * d <= c * b
  defp low(values), do: Enum.reduce(values, fn a, b -> if le?(a, b), do: a, else: b end)
  defp high(values), do: Enum.reduce(values, fn a, b -> if le?(a, b), do: b, else: a end)
  defp floor_r({n, d}), do: Integer.floor_div(n, d)
  defp ceil_r({n, d}), do: -Integer.floor_div(-n, d)
  defp trunc_r({n, d}), do: div(n, d)
  def integer(v) when is_integer(v), do: v
  def integer(v) when is_binary(v), do: String.to_integer(v)

  defp clock!(directory, cfg, stream, name, edge, num, den) do
    clock = stream["clock"]

    if clock["state"] != "bounded" or edge == 0 do
      %{state: "unavailable", tested: 0, violations: 0}
    else
      identity = read(Path.join([directory, "spool", cfg["acquisition"], "identity.json"]))
      mapping = clock["wall_mapping"]
      fit = clock["estimate"]
      vertices = Enum.map(fit["vertices"], fn [k, t] -> {fraction(k), fraction(t)} end)
      [observed_first, observed_last] = Enum.map(fit["probe_span_us"], &fraction/1)
      holdover = fraction(fit["holdover_rate"])
      indices = Enum.uniq([0, div(edge, 3), div(edge, 2), edge - 1]) |> Enum.sort()

      failed =
        Enum.filter(indices, fn i ->
          device = add({180_000, 1}, ratio(i * 1_000_000 * den, num))
          a = sub(device, {2, 1})
          b = add(device, {2, 1})
          error = mul(high([{0, 1}, sub(observed_first, a), sub(b, observed_last)]), holdover)
          lo = sub(low(Enum.map(vertices, fn {k, t} -> add(mul(k, a), t) end)), error)
          hi = add(high(Enum.map(vertices, fn {k, t} -> add(mul(k, b), t) end)), error)
          drift = if name == "audio", do: 35, else: -40

          ground =
            integer(identity["origin_us"]) +
              trunc_r(mul(sub(device, {180_000, 1}), ratio(1_000_000 + drift, 1_000_000)))

          lower =
            ground + integer(mapping["host_monotonic_us"]) - integer(mapping["wall_after_us"])

          upper =
            ground + integer(mapping["host_monotonic_us"]) - integer(mapping["wall_before_us"])

          floor_r(lo) > lower or ceil_r(hi) < upper
        end)

      %{
        state: "bounded",
        tested: length(indices),
        violations: length(failed),
        failed_samples: failed
      }
    end
  end

  def restart_cutoff!(root) do
    cursor_path = Path.join(root, "source.json")

    cursor =
      if File.exists?(cursor_path), do: read(cursor_path), else: %{"sequence" => 0, "sample" => 0}

    check!(not cursor["done"], "Restart fixture already completed")
    sequence = integer(cursor["sequence"])
    sample = integer(cursor["sample"])
    receipt_path = Path.join(root, "ack.json")

    if File.exists?(receipt_path) do
      receipt = read(receipt_path)["receipt"]
      durable_sequence = integer(receipt["durable_sequence"])
      durable_sample = integer(receipt["durable_sample"])

      check!(
        (durable_sequence <= sequence and durable_sample < sample) or
          (durable_sequence >= sequence and durable_sample > sample) or
          {durable_sequence, durable_sample} == {sequence, sample},
        "Restart receipt and source cursor disagree"
      )

      cutoff!(root, max(sequence, durable_sequence), max(sample, durable_sample))
    else
      cutoff!(root, sequence, sample)
    end
  end

  defp cutoff!(root, sequence, sample) do
    path = Path.join(root, "#{sequence}-#{sample}.rec")

    case File.read(path) do
      {:error, :enoent} ->
        sample

      {:ok, <<digest::binary-size(32), frame::binary>>} ->
        check!(:crypto.hash(:sha256, frame) == digest, "Corrupt independent spool record")

        case frame do
          <<"MEX1", 1, 0, 48::unsigned-big-16, _handle::32, _epoch::32, _config::32,
            ^sequence::unsigned-big-64, ^sample::unsigned-big-64, count::unsigned-big-32,
            size::unsigned-big-32, 0::32, payload::binary>>
          when size == byte_size(payload) ->
            check!(count > 0 and size > 0 and size <= 65_536, "Invalid independent frame")
            cutoff!(root, sequence + 1, sample + count)

          _ ->
            gap = JSON.decode!(frame)

            check!(
              Enum.sort(Map.keys(gap)) ==
                Enum.sort(~w(id first end first_sequence next_sequence irreversible cause)) and
                is_binary(gap["id"]) and gap["id"] != "" and
                is_binary(gap["cause"]) and gap["cause"] != "" and
                gap["irreversible"] == true and
                Enum.all?(~w(first end first_sequence next_sequence), fn key ->
                  is_binary(gap[key]) and Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, gap[key])
                end) and integer(gap["first_sequence"]) == sequence and
                integer(gap["first"]) == sample,
              "Invalid independent source gap"
            )

            next_sequence = integer(gap["next_sequence"])
            next_sample = integer(gap["end"])

            check!(
              next_sequence >= sequence and next_sample > sample,
              "Nonprogressing source gap"
            )

            cutoff!(root, next_sequence, next_sample)
        end

      other ->
        raise "Invalid spool record: #{inspect(elem(other, 0))}"
    end
  end
end
