defmodule MedFabric.Handheld.SpoolReceiptTest do
  use ExUnit.Case, async: true
  alias MedEx.Receipt
  alias MedEx.Wire.FrameV1
  alias MedFabric.Handheld.{Paired, Spool}
  alias MedFabric.Handheld.Spool.Plan

  setup do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), "mf-spool-" <> suffix)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)

    {_, spec} =
      Paired.sources(%{
        "device" => "fixture",
        "acquisition" => "acq",
        "boot" => "gateway-boot",
        "seed" => 1
      })["audio"]

    pid = start_supervised!({Spool, root: dir, limit: 1_048_576})
    assert :ok = Spool.register(pid, spec)
    {:ok, spool: pid, spec: spec, root: dir}
  end

  test "activation validates durable truth and coverage before replacing recovery state", c do
    initial = receipt(c.spec, 0, 0, 1)
    reply = reply(initial, 1, "connection-a")
    assert {:ok, _} = Spool.activate(c.spool, "audio", c.spec, reply)
    persisted = File.read!(Path.join([c.root, "audio", "ack.json"]))

    for bad <- [nil, [], %{}, Map.put(initial, "accepted_sample", "1"), receipt(c.spec, 9, 9, 2)] do
      assert {:error, _} = Spool.activate(c.spool, "audio", c.spec, %{reply | "receipt" => bad})
      assert File.read!(Path.join([c.root, "audio", "ack.json"])) == persisted
    end

    put(c, 0, 0)
    assert :ok = Spool.ack(c.spool, "audio", reply["binding"], receipt(c.spec, 1, 1, 2))
    assert :absent = Spool.get(c.spool, "audio", {0, 0})
  end

  test "late committed ACK after local invalidation cannot reclaim or change watermark", c do
    put(c, 0, 0)
    initial = reply(receipt(c.spec, 0, 0, 1), 1, "old")
    assert {:ok, _} = Spool.activate(c.spool, "audio", c.spec, initial)
    assert :ok = Spool.invalidate(c.spool, initial["binding"])

    assert {:error, :stale_binding} =
             Spool.ack(c.spool, "audio", initial["binding"], receipt(c.spec, 1, 1, 2))

    assert {:ok, _} = Spool.get(c.spool, "audio", {0, 0})
    fresh = reply(receipt(c.spec, 1, 1, 2), 1, "fresh")
    assert {:ok, _} = Spool.activate(c.spool, "audio", c.spec, fresh)
    assert :absent = Spool.get(c.spool, "audio", {0, 0})
  end

  test "sample-only gap and following frame share sequence without sharing storage key", c do
    gap =
      MedEx.CanonicalJSON.encode(%{
        "id" => "loss",
        "irreversible" => true,
        "cause" => "source_loss",
        "first" => "0",
        "end" => "4",
        "first_sequence" => "0",
        "next_sequence" => "0"
      })

    assert :ok =
             Spool.put_batch_and_advance(c.spool, c.root, "audio", [
               {0, gap, 0, 4},
               {0, frame(0, 4), 1, 5}
             ])

    initial = reply(receipt(c.spec, 0, 0, 1), 1, "current")
    assert {:ok, _} = Spool.activate(c.spool, "audio", c.spec, initial)
    assert :ok = Spool.ack(c.spool, "audio", initial["binding"], receipt(c.spec, 0, 4, 2))
    assert :absent = Spool.get(c.spool, "audio", {0, 0})
    assert {:ok, _} = Spool.get(c.spool, "audio", {0, 4})
    assert :ok = Spool.ack(c.spool, "audio", initial["binding"], receipt(c.spec, 1, 5, 3))
  end

  test "spool gap IDs leave room for the canonical wire operation prefix", c do
    for size <- [92, 93, 96] do
      gap = %{
        "id" => String.duplicate("a", size),
        "irreversible" => true,
        "cause" => "source_loss",
        "first" => "0",
        "end" => "4",
        "first_sequence" => "0",
        "next_sequence" => "0"
      }

      raw = MedEx.CanonicalJSON.encode(gap)
      result = Plan.record(raw, c.spec)

      if size == 92 do
        assert {:ok, metadata} = result
        assert metadata.id == "gap-" <> gap["id"]
        assert byte_size(metadata.id) == 96
        assert metadata.fingerprint == MedEx.Serialization.sha256(raw)
      else
        assert {:error, :invalid_source_gap} = result
      end
    end
  end

  test "hybrid durable activation never reclaims retained source bytes", c do
    put(c, 0, 0)
    valid = reply(receipt(c.spec, 1, 1, 2), 1, "current")

    for fields <- [
          %{"event_id" => "event"},
          %{"fingerprint" => String.duplicate("a", 64)},
          %{"event_id" => nil}
        ] do
      assert {:error, :invalid_activation} =
               Spool.activate(c.spool, "audio", c.spec, Map.merge(valid, fields))

      assert {:ok, _} = Spool.get(c.spool, "audio", {0, 0})
      refute File.exists?(Path.join([c.root, "audio", "ack.json"]))
    end
  end

  test "foreign identity same-generation conflict rollback and missing handoff preserve bytes",
       c do
    for n <- 0..3, do: put(c, n, n)
    initial = reply(receipt(c.spec, 0, 0, 1), 1, "old")
    assert {:ok, _} = Spool.activate(c.spool, "audio", c.spec, initial)
    committed = receipt(c.spec, 2, 2, 4)
    assert :ok = Spool.ack(c.spool, "audio", initial["binding"], committed)

    for changed <- [
          Map.put(committed, "journal_digest", String.duplicate("f", 64)),
          receipt(c.spec, 1, 1, 5),
          Map.put(receipt(c.spec, 3, 3, 5), "stream_id", "ecg")
        ] do
      assert {:error, _} = Spool.ack(c.spool, "audio", initial["binding"], changed)
      assert {:ok, _} = Spool.get(c.spool, "audio", {2, 2})
    end

    successor =
      committed
      |> Map.put("fence", "new")
      |> Map.put("journal_id", "new-journal")
      |> Map.put("journal_generation", "1")
      |> Map.put("journal_digest", MedEx.Serialization.sha256("new"))

    fresh = reply(successor, 2, "new")
    assert {:error, _} = Spool.activate(c.spool, "audio", c.spec, fresh)

    handoff = %{
      "previous" => committed,
      "successor" => successor,
      "imported" => committed,
      "asserted_by" => "authenticated_host"
    }

    assert {:ok, _} = Spool.activate(c.spool, "audio", c.spec, Map.put(fresh, "handoff", handoff))

    assert {:error, :stale_binding} =
             Spool.ack(c.spool, "audio", initial["binding"], receipt(c.spec, 3, 3, 5))
  end

  test "restart recovers synchronized tail and an ACK persisted before record deletion", c do
    for n <- 0..4, do: put(c, n, n)
    initial = reply(receipt(c.spec, 0, 0, 1), 1, "old")
    assert {:ok, _} = Spool.activate(c.spool, "audio", c.spec, initial)

    Spool.write!(
      Path.join([c.root, "audio", "ack.json"]),
      JSON.encode!(%{"binding" => initial["binding"], "receipt" => receipt(c.spec, 3, 3, 2)})
    )

    stop_supervised!(Spool)
    pid = start_supervised!({Spool, root: c.root, limit: 1_048_576})
    assert :ok = Spool.register(pid, c.spec)
    assert %{"sequence" => 5, "sample" => 5} = Spool.watermark(pid, "audio")
    assert :ok = Paired.interrupt_after_restart(%{"spool" => c.root}, pid, "audio", c.spec)
    assert %{"done" => true, "interruption" => "source_reset"} = Spool.watermark(pid, "audio")

    assert {:ok, _} =
             Spool.activate(pid, "audio", c.spec, reply(receipt(c.spec, 3, 3, 2), 1, "new"))

    assert :absent = Spool.get(pid, "audio", {0, 0})
    assert {:ok, _} = Spool.get(pid, "audio", {3, 3})
  end

  test "reclamation counts only covered records as backlog grows", c do
    for n <- 0..499, do: put(c, n, n)
    initial = reply(receipt(c.spec, 0, 0, 1), 1, "current")
    assert {:ok, _} = Spool.activate(c.spool, "audio", c.spec, initial)
    before = Spool.stats(c.spool).reclamation_visits
    assert :ok = Spool.ack(c.spool, "audio", initial["binding"], receipt(c.spec, 15, 15, 2))
    assert Spool.stats(c.spool).reclamation_visits - before == 15
    before = Spool.stats(c.spool).reclamation_visits
    assert :ok = Spool.ack(c.spool, "audio", initial["binding"], receipt(c.spec, 15, 15, 2))
    assert Spool.stats(c.spool).reclamation_visits == before
    assert {:ok, _} = Spool.get(c.spool, "audio", {499, 499})
  end

  test "old namespaces, corrupt records and concurrent flock owner fail closed", c do
    assert {:error, _} = Spool.start_link(root: c.root, limit: 4096)
    put(c, 0, 0)
    stop_supervised!(Spool)
    path = Path.join([c.root, "audio", "0-0.rec"])
    File.write!(path, "broken")
    assert {:error, _} = Spool.start_link(root: c.root, limit: 4096)
    assert File.read!(path) == "broken"
    old = Path.join(c.root, "old")
    File.mkdir_p!(old)
    File.chmod!(old, 0o700)
    File.write!(Path.join(old, "identity.json"), "{}")
    before = File.ls!(old) |> Enum.sort()
    assert {:error, :incompatible_spool} = Spool.start_link(root: old, limit: 4096)
    assert Enum.sort(File.ls!(old)) == before
    assert File.read!(Path.join(old, "identity.json")) == "{}"
  end

  test "a record changed after load cannot become covered or reclaimable", c do
    put(c, 0, 0)
    initial = reply(receipt(c.spec, 0, 0, 1), 1, "active")
    assert {:ok, _} = Spool.activate(c.spool, "audio", c.spec, initial)
    ack_path = Path.join([c.root, "audio", "ack.json"])
    persisted = File.read!(ack_path)
    record = Path.join([c.root, "audio", "0-0.rec"])
    {:ok, decoded} = FrameV1.decode(frame(0, 0))
    {:ok, changed} = FrameV1.encode(%{decoded | payload: <<7, 0>>})
    File.write!(record, :crypto.hash(:sha256, changed) <> changed)

    assert {:error, :source_record_changed} =
             Spool.ack(c.spool, "audio", initial["binding"], receipt(c.spec, 1, 1, 2))

    assert File.read!(ack_path) == persisted
    assert File.exists?(record)
  end

  test "an exact record replay still has to name its exact ending cursor", c do
    put(c, 0, 0)

    assert {:error, :spool_conflict} =
             Spool.put_batch_and_advance(c.spool, c.root, "audio", [{0, frame(0, 0), 2, 99}])

    assert %{"sequence" => 1, "sample" => 1} = Spool.watermark(c.spool, "audio")
  end

  for stored_ack? <- [true, false] do
    @tag stored_ack?: stored_ack?
    test "authenticated predecessor import with stored ACK #{stored_ack?}", c do
      for q <- 0..2, do: put(c, q, q)
      previous = receipt(c.spec, 0, 0, 1)

      if c.stored_ack?,
        do: assert({:ok, _} = Spool.activate(c.spool, "audio", c.spec, reply(previous, 1, "old")))

      recovered = receipt(c.spec, 2, 2, 3)

      successor =
        recovered
        |> Map.put("fence", "successor")
        |> Map.put("journal_id", "next-journal")
        |> Map.put("journal_generation", "1")
        |> Map.put("journal_digest", MedEx.Serialization.sha256("successor"))

      handoff = %{
        "previous" => recovered,
        "successor" => successor,
        "imported" => recovered,
        "asserted_by" => "authenticated_host"
      }

      assert {:ok, _} =
               Spool.activate(
                 c.spool,
                 "audio",
                 c.spec,
                 Map.put(reply(successor, 2, "fresh"), "handoff", handoff)
               )

      assert :absent = Spool.get(c.spool, "audio", {1, 1})
      assert {:ok, _} = Spool.get(c.spool, "audio", {2, 2})
    end
  end

  test "duplicate metadata keys and symlinked metadata cannot replace recovery state", c do
    file = Path.join(c.root, "duplicate.json")
    File.write!(file, ~s({"sequence":0,"sequence":9}))
    assert_raise ArgumentError, fn -> Spool.read_json(file, nil) end
    linked = Path.join(c.root, "link.json")
    File.ln_s!(file, linked)
    assert_raise ArgumentError, fn -> Spool.read_json(linked, nil) end
  end

  test "a partially installed capacity-limited batch recovers its actual prefix", c do
    stop_supervised!(Spool)
    size = byte_size(frame(0, 0)) + 32
    spool = start_supervised!({Spool, root: c.root, limit: size})
    assert :ok = Spool.register(spool, c.spec)

    assert {:error, :spool_full} =
             Spool.put_batch_and_advance(spool, c.root, "audio", [
               {0, frame(0, 0), 1, 1},
               {1, frame(1, 1), 2, 2}
             ])

    assert %{"sequence" => 1, "sample" => 1} = Spool.watermark(spool, "audio")
    assert {:ok, _} = Spool.get(spool, "audio", {0, 0})
    assert :absent = Spool.get(spool, "audio", {1, 1})
    stop_supervised!(Spool)
    spool = start_supervised!({Spool, root: c.root, limit: size})
    assert :ok = Spool.register(spool, c.spec)
    assert :ok = Paired.interrupt_after_restart(%{}, spool, "audio", c.spec)

    assert %{"sequence" => 1, "sample" => 1, "interruption" => "source_reset"} =
             Spool.watermark(spool, "audio")
  end

  test "restart removes only uncommitted staging names and never installs their bytes", c do
    put(c, 0, 0)
    stop_supervised!(Spool)
    pending = Path.join([c.root, "audio", "1-1.rec.tmp.AAAAAAAAAAAAAAAA"])
    File.write!(pending, "partial bytes")
    spool = start_supervised!({Spool, root: c.root})
    assert :ok = Spool.register(spool, c.spec)
    assert %{"sequence" => 1, "sample" => 1} = Spool.watermark(spool, "audio")
    refute File.exists?(pending)
    assert {:ok, _} = Spool.get(spool, "audio", {0, 0})
  end

  defp put(c, q, first),
    do:
      assert(
        :ok =
          Spool.put_batch_and_advance(c.spool, c.root, "audio", [
            {q, frame(q, first), q + 1, first + 1}
          ])
      )

  defp frame(q, first) do
    {:ok, bytes} =
      FrameV1.encode(%FrameV1{
        stream_number: 1,
        source_epoch: 0,
        config_epoch: 0,
        sequence: q,
        first_sample: first,
        sample_count: 1,
        payload: <<4, 0>>
      })

    bytes
  end

  defp receipt(spec, q, sample, gen) do
    %{
      "stream_id" => "audio",
      "source_epoch" => "0",
      "descriptor_ref" => spec.descriptor_ref,
      "fence" => "fence",
      "journal_id" => "journal",
      "journal_generation" => to_string(gen),
      "journal_digest" => MedEx.Serialization.sha256(to_string(gen)),
      "accepted_sequence" => to_string(q),
      "accepted_sample" => to_string(sample),
      "durable_sequence" => to_string(q),
      "durable_sample" => to_string(sample)
    }
  end

  defp reply(receipt, gen, connection) do
    assert {:ok, _} = Receipt.parse(receipt)

    %{
      "type" => "durable",
      "receipt" => receipt,
      "binding" => %{
        "acquisition" => "acq",
        "profile" => "paired_exam",
        "generation" => to_string(gen),
        "connection" => connection,
        "stream" => "audio",
        "fence" => receipt["fence"],
        "journal_id" => receipt["journal_id"]
      }
    }
  end
end
