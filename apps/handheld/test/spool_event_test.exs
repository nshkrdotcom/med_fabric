defmodule MedExHandheld.SpoolEventTest do
  use ExUnit.Case, async: true
  alias MedExHandheld.{PLXPeripheral, Spool}

  setup do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    root = Path.join(System.tmp_dir!(), "mf-spool-" <> suffix)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    spool = start_supervised!({Spool, root: root})

    identity = %{
      "acquisition" => "collection",
      "profile" => "plx_spot_check",
      "device" => "gateway",
      "boot" => "boot"
    }

    Spool.write!(Path.join(root, "identity.json"), JSON.encode!(identity))

    events =
      for {raw, q} <- Enum.with_index(PLXPeripheral.new().records),
          do: PLXPeripheral.event(raw, "event-#{q}", q, nil, identity, :fixed_fixture_utc)

    for {event, q} <- Enum.with_index(events),
        do: assert(:ok = Spool.put(spool, "events", q, MedEx.CanonicalJSON.encode(event)))

    binding = %{
      "acquisition" => "collection",
      "profile" => "plx_spot_check",
      "generation" => "2",
      "connection" => "current"
    }

    assert :ok = Spool.event_activate(spool, binding)

    {:ok,
     spool: spool,
     root: root,
     binding: binding,
     events: events,
     inventory: Enum.map(events, &[&1["event_id"], MedEx.Serialization.digest(&1)])}
  end

  test "event ACK checks sequence body fingerprint and current connection", c do
    [id, digest] = hd(c.inventory)
    assert {:error, :event_conflict} = Spool.event_ack(c.spool, c.binding, 1, id, digest)

    assert {:error, :event_conflict} =
             Spool.event_ack(c.spool, c.binding, 0, id, String.duplicate("f", 64))

    assert :ok = Spool.event_ack(c.spool, c.binding, 0, id, digest)
    assert {:ok, _} = Spool.get(c.spool, "events", 0)
    assert :ok = Spool.invalidate(c.spool, c.binding)
    assert {:error, :event_conflict} = Spool.event_ack(c.spool, c.binding, 0, id, digest)

    assert {:error, :invalid_binding} =
             Spool.event_activate(c.spool, Map.put(c.binding, "generation", "1"))

    assert {:error, :invalid_binding} =
             Spool.event_activate(c.spool, Map.put(c.binding, "acquisition", "foreign"))
  end

  test "complete fresh remote inventory covers lost individual ACK and restart after partial deletion",
       c do
    assert :ok = Spool.event_seal(c.spool, c.binding, c.inventory)
    assert :absent = Spool.get(c.spool, "events", 0)
    stop_supervised!(Spool)
    spool = start_supervised!({Spool, root: c.root})
    fresh = Map.put(c.binding, "connection", "fresh")
    assert :ok = Spool.event_activate(spool, fresh)
    assert :ok = Spool.event_seal(spool, fresh, c.inventory)

    assert {:error, :event_inventory_conflict} =
             Spool.event_seal(spool, fresh, Enum.reverse(c.inventory))
  end

  test "incomplete or wrong remote inventory cannot authorize cleanup", c do
    assert {:error, :event_inventory_conflict} =
             Spool.event_seal(c.spool, c.binding, Enum.take(c.inventory, 1))

    assert {:error, :event_inventory_conflict} =
             Spool.event_seal(c.spool, c.binding, [hd(c.inventory), hd(c.inventory)])

    assert {:ok, _} = Spool.get(c.spool, "events", 0)
    assert {:ok, _} = Spool.get(c.spool, "events", 1)
  end
end
