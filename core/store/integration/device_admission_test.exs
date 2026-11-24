defmodule MedFabric.Store.DeviceAdmissionTest do
  use ExUnit.Case, async: false

  alias MedFabric.Store.{DeviceCommands, DeviceSessions, MeasurementEvents, Postgres, Records}
  alias DeviceSessions, as: S

  # Run explicitly against an isolated integration database:
  # DATABASE_URL=... mix test integration/device_admission_test.exs
  setup do
    db = start_supervised!({Postgres,
      url: System.fetch_env!("DATABASE_URL"), name: Postgres, pool_size: 6})
    assert {:ok, :ok} = Postgres.migrate(db)
    suffix = Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
    enc = "admission-" <> suffix
    device = "handheld-" <> suffix
    actor = "clinician-" <> suffix
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    assert :ok = Records.open(db, enc, "patient-" <> suffix, actor)
    assert S.enroll(device, token)
    for profile <- ["paired_exam", "plx_spot_check"] do
      assert :ok = S.authorize(enc, device, profile, "left-upper-chest", actor)
    end
    %{db: db, enc: enc, device: device, actor: actor, token: token}
  end

  test "schema migration repeats without losing existing legacy or device records", c do
    before = S.rows(c.db, "SELECT name FROM mf_schema_history ORDER BY name", [])
    assert ["005_device_acquisitions.sql"] in before
    assert {:ok, :ok} = Postgres.migrate(c.db)
    assert S.rows(c.db, "SELECT name FROM mf_schema_history ORDER BY name", []) == before
    device = c.device
    assert {:ok, ^device} = S.authenticate(c.token)
    assert :ok = Records.reserve(c.db, c.enc, "legacy-" <> c.enc, "patient-" <> String.replace_prefix(c.enc, "admission-", ""))
    assert {:error, :active_slot_busy} = reserve(c, "plx_spot_check", "device-" <> c.enc)
  end

  test "competing profiles share one acquisition slot, including pending finalization", c do
    tasks = for profile <- ["paired_exam", "plx_spot_check"] do
      Task.async(fn -> reserve(c, profile, profile <> "-" <> c.enc) end)
    end
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :active_slot_busy})) == 1
    {:ok, winner} = Enum.find(results, &match?({:ok, _}, &1))
    S.rows(c.db, "UPDATE device_sessions SET phase='finalizing' WHERE id=$1", [winner.id])
    assert {:error, :active_slot_busy} = reserve(c, "plx_spot_check", "next-" <> c.enc)
  end

  test "resume rotates the generation and revocation fences every admitted effect", c do
    assert {:ok, old} = reserve(c, "paired_exam", "resume-" <> c.enc)
    assert {:ok, current} = reserve(c, "paired_exam", old.id)
    assert current.generation == old.generation + 1
    refute current.lease == old.lease
    assert {:error, :stale_lease} = S.scoped(old, fn _, _ -> :should_not_run end)
    assert {:ok, :admitted} = S.scoped(current, fn _, _ -> :admitted end)
    assert {:error, :resume_conflict} = S.reserve(c.device, c.enc, old.id,
      "paired_exam", "different-boot", %{})
    assert {:error, :denied} = S.authorize(c.enc, c.device, "paired_exam", "site", "other-clinician")
    assert {:error, :grant_denied} = S.reserve(c.device, "other-encounter", "other",
      "paired_exam", "boot-a", %{})
    S.rows(c.db, "UPDATE device_credentials SET revoked=true WHERE device_id=$1", [c.device])
    assert {:error, :denied} = S.authenticate(c.token)
    assert {:error, :stale_lease} = S.scoped(current, fn _, _ -> :should_not_run end)
  end

  test "exact measurement replay is idempotent and conflict or unseen sealed input is quarantined", c do
    assert {:ok, bind} = reserve(c, "plx_spot_check", "inventory-" <> c.enc)
    event = %{"event_id" => "one", "gateway_sequence" => "0", "simulated" => true}
    assert {:ok, :durable} = MeasurementEvents.put(bind, event, S.hash("one"))
    assert {:ok, :durable} = MeasurementEvents.put(bind, event, S.hash("one"))
    assert {:ok, :quarantined} = MeasurementEvents.put(bind, event, S.hash("changed"))
    S.rows(c.db, "UPDATE device_sessions SET phase='sealed' WHERE id=$1", [bind.id])
    assert {:ok, :durable} = MeasurementEvents.put(bind, event, S.hash("one"))
    assert {:ok, :quarantined} = MeasurementEvents.put(bind,
      %{"event_id" => "two", "gateway_sequence" => "1"}, S.hash("two"))
    assert [[1]] = S.rows(c.db, "SELECT count(*) FROM measurement_events WHERE acquisition_id=$1", [bind.id])
    assert [[2]] = S.rows(c.db, "SELECT count(*) FROM device_facts WHERE acquisition_id=$1 AND kind='quarantine'", [bind.id])
  end

  test "timed out command stays unknown until a matching state result reconciles it", c do
    assert {:ok, bind} = reserve(c, "paired_exam", "command-" <> c.enc)
    assert {:ok, :ok} = DeviceCommands.request(c.enc, bind.id, c.actor, "half")
    assert {:ok, %{"type" => "command"} = command} = DeviceCommands.poll(bind)
    assert {:ok, %{"type" => "heartbeat"}} = DeviceCommands.poll(bind)
    S.rows(c.db, "UPDATE device_commands SET updated_at=now()-interval '4 seconds' WHERE id=$1", [command["id"]])
    assert {:ok, %{"type" => "state_query"} = query} = DeviceCommands.poll(bind)
    assert query["id"] == command["id"]
    assert {:error, :reconciliation_required} = DeviceCommands.request(c.enc, bind.id, c.actor, "unity")
    result = Map.take(command, ["id", "fingerprint", "boot", "gain"])
      |> Map.merge(%{"status" => "reconciled", "epoch" => "1"})
    assert {:error, :command_conflict} = DeviceCommands.result(bind, Map.put(result, "boot", "wrong-boot"))
    assert {:ok, :ok} = DeviceCommands.result(bind, result)
    assert {:ok, :ok} = DeviceCommands.result(bind, result)
    assert [["command_dispatching"], ["command_outcome_unknown"], ["command_reconciled"]] =
      S.rows(c.db, "SELECT kind FROM device_facts WHERE acquisition_id=$1 AND kind != 'command_requested' ORDER BY ordinal", [bind.id])
    assert {:ok, :ok} = DeviceCommands.request(c.enc, bind.id, c.actor, "unity")
  end

  defp reserve(c, profile, id), do: S.reserve(c.device, c.enc, id, profile, "boot-a", %{})
end
