defmodule MedFabric.Store.DeviceAdmissionTest do
  use ExUnit.Case, async: false

  alias MedFabric.Store.DeviceCommands
  alias MedFabric.Store.DeviceSessions, as: S
  alias MedFabric.Store.{MeasurementEvents, Postgres, Records}

  # Run explicitly against an isolated integration database:
  # DATABASE_URL=... mix test integration/device_admission_test.exs
  setup do
    db =
      start_supervised!(
        {Postgres, url: System.fetch_env!("DATABASE_URL"), name: Postgres, pool_size: 6}
      )

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

    assert :ok =
             Records.reserve(
               c.db,
               c.enc,
               "legacy-" <> c.enc,
               "patient-" <> String.replace_prefix(c.enc, "admission-", "")
             )

    assert {:ok, _} = reserve(c, "plx_spot_check", "device-" <> c.enc)
  end

  test "distinct profiles run concurrently while duplicate same-profile slots conflict, including pending finalization",
       c do
    assert {:ok, paired} = reserve(c, "paired_exam", "paired-" <> c.enc)
    assert {:ok, plx} = reserve(c, "plx_spot_check", "plx-" <> c.enc)

    tasks =
      for suffix <- ["a", "b"] do
        Task.async(fn -> reserve(c, "plx_spot_check", "dup-#{suffix}-" <> c.enc) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.all?(results, &(&1 == {:error, :active_slot_busy}))

    S.rows(c.db, "UPDATE device_sessions SET phase='finalizing' WHERE id=$1", [plx.id])
    assert {:error, :active_slot_busy} = reserve(c, "plx_spot_check", "next-" <> c.enc)
    assert {:error, :active_slot_busy} = reserve(c, "paired_exam", "next-paired-" <> c.enc)
    assert paired.id != plx.id
  end

  test "resume rotates the generation and revocation fences every admitted effect", c do
    assert {:ok, old} = reserve(c, "paired_exam", "resume-" <> c.enc)
    assert {:ok, current} = reserve(c, "paired_exam", old.id)
    assert current.generation == old.generation + 1
    refute current.lease == old.lease
    assert {:error, :stale_lease} = S.scoped(old, fn _, _ -> :should_not_run end)
    assert {:ok, :admitted} = S.scoped(current, fn _, _ -> :admitted end)

    assert {:error, :resume_conflict} =
             S.reserve(c.device, c.enc, old.id, "paired_exam", "different-boot", %{})

    assert {:error, :denied} =
             S.authorize(c.enc, c.device, "paired_exam", "site", "other-clinician")

    assert {:error, :grant_denied} =
             S.reserve(c.device, "other-encounter", "other", "paired_exam", "boot-a", %{})

    S.rows(c.db, "UPDATE device_credentials SET revoked=true WHERE device_id=$1", [c.device])
    assert {:error, :denied} = S.authenticate(c.token)
    assert {:error, :stale_lease} = S.scoped(current, fn _, _ -> :should_not_run end)
  end

  test "resume waiting on a session does not block a scoped grant read", c do
    assert {:ok, bind} = reserve(c, "paired_exam", "lock-order-" <> c.enc)
    owner = self()

    holder =
      Task.async(fn ->
        Postgrex.transaction(c.db, fn tx ->
          [[backend]] = S.rows(tx, "SELECT pg_backend_pid()", [])
          S.rows(tx, "SELECT id FROM device_sessions WHERE id=$1 FOR SHARE", [bind.id])
          send(owner, {:session_locked, backend})

          receive do
            :read_grant ->
              S.rows(tx, """
              SELECT site FROM device_grants
              WHERE encounter_id=$1 AND device_id=$2 AND profile='paired_exam' FOR SHARE
              """, [c.enc, c.device])
          after
            5000 -> raise "resume did not reach the held session lock"
          end
        end)
      end)

    assert_receive {:session_locked, backend}, 2000
    resume = Task.async(fn -> reserve(c, "paired_exam", bind.id) end)

    assert Enum.any?(1..100, fn _ ->
      [[waiting]] =
        S.rows(c.db, "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)))",
          [backend])

      unless waiting, do: Process.sleep(10)
      waiting
    end)

    send(holder.pid, :read_grant)
    assert {:ok, [["left-upper-chest"]]} = Task.await(holder)
    assert {:ok, next} = Task.await(resume)
    assert next.generation == bind.generation + 1
  end

  test "exact measurement replay is idempotent and conflict or unseen sealed input is quarantined",
       c do
    assert {:ok, bind} = reserve(c, "plx_spot_check", "inventory-" <> c.enc)
    event = %{"event_id" => "one", "gateway_sequence" => "0", "simulated" => true}
    assert {:ok, :durable} = MeasurementEvents.put(bind, event, S.hash("one"))
    assert {:ok, :durable} = MeasurementEvents.put(bind, event, S.hash("one"))
    assert {:ok, :quarantined} = MeasurementEvents.put(bind, event, S.hash("changed"))
    S.rows(c.db, "UPDATE device_sessions SET phase='sealed' WHERE id=$1", [bind.id])
    assert {:ok, :durable} = MeasurementEvents.put(bind, event, S.hash("one"))

    assert {:ok, :quarantined} =
             MeasurementEvents.put(
               bind,
               %{"event_id" => "two", "gateway_sequence" => "1"},
               S.hash("two")
             )

    assert [[1]] =
             S.rows(c.db, "SELECT count(*) FROM measurement_events WHERE acquisition_id=$1", [
               bind.id
             ])

    assert [[2]] =
             S.rows(
               c.db,
               "SELECT count(*) FROM device_facts WHERE acquisition_id=$1 AND kind='quarantine'",
               [bind.id]
             )
  end

  test "command uses the highest confirmed epoch for the admitted boot", c do
    assert {:ok, bind} = reserve(c, "paired_exam", "epochs-" <> c.enc)

    for {suffix, boot, epoch, seconds_old} <- [
          {"older", bind.boot, "10", 20},
          {"newer", bind.boot, "2", 10},
          {"other-boot", "other-boot", "99", 1}
        ] do
      S.rows(c.db, """
      INSERT INTO device_commands(id,acquisition_id,fingerprint,request,state,result,updated_at)
      VALUES($1,$2,'test',$3,'applied',$4,clock_timestamp()-$5::int*interval '1 second')
      """, [bind.id <> suffix, bind.id, %{"boot" => boot}, %{"epoch" => epoch}, seconds_old])
    end

    assert {:ok, :ok} = DeviceCommands.request(c.enc, bind.id, c.actor, "half")
    assert {:ok, %{"type" => "command", "expected_epoch" => "10"}} = DeviceCommands.poll(bind)
  end

  test "timed out command stays unknown until a matching state result reconciles it", c do
    assert {:ok, bind} = reserve(c, "paired_exam", "command-" <> c.enc)
    assert {:ok, :ok} = DeviceCommands.request(c.enc, bind.id, c.actor, "half")
    assert {:ok, %{"type" => "command"} = command} = DeviceCommands.poll(bind)
    assert {:ok, %{"type" => "heartbeat"}} = DeviceCommands.poll(bind)

    S.rows(c.db, "UPDATE device_commands SET updated_at=now()-interval '4 seconds' WHERE id=$1", [
      command["id"]
    ])

    assert {:ok, %{"type" => "state_query"} = query} = DeviceCommands.poll(bind)
    assert query["id"] == command["id"]

    assert {:error, :reconciliation_required} =
             DeviceCommands.request(c.enc, bind.id, c.actor, "unity")

    result =
      Map.take(command, ["id", "fingerprint", "boot", "gain"])
      |> Map.merge(%{"status" => "reconciled", "epoch" => "1"})

    assert {:error, :command_conflict} =
             DeviceCommands.result(bind, Map.put(result, "boot", "wrong-boot"))

    assert {:ok, :ok} = DeviceCommands.result(bind, result)
    assert {:ok, :ok} = DeviceCommands.result(bind, result)

    assert [["command_dispatching"], ["command_outcome_unknown"], ["command_reconciled"]] =
             S.rows(
               c.db,
               "SELECT kind FROM device_facts WHERE acquisition_id=$1 AND kind != 'command_requested' ORDER BY ordinal",
               [bind.id]
             )

    assert {:ok, :ok} = DeviceCommands.request(c.enc, bind.id, c.actor, "unity")
  end

  test "command and heartbeat progress during a locked stream, then revocation fences both", c do
    assert {:ok, bind} = reserve(c, "paired_exam", "stall-" <> c.enc)
    audio = create_attempt(c.db, bind, "audio", 1)
    ecg = create_attempt(c.db, bind, "ecg", 2)
    parent = self()

    stalled =
      Task.async(fn ->
        S.scoped(bind, fn tx, _ ->
          update_receipt(tx, ecg, "13")
          hold_transaction(tx, parent, :stream_held)
        end)
      end)

    assert_receive {:stream_held, stream_backend}, 3000

    assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
             Postgrex.query(
               c.db,
               "SELECT fence FROM stream_attempts WHERE fence=$1 FOR UPDATE NOWAIT",
               [ecg]
             )

    gate =
      Task.async(fn ->
        Postgrex.transaction(c.db, fn tx ->
          S.rows(tx, "SELECT pg_advisory_xact_lock(hashtextextended($1,73160650))", [bind.id])
          hold_transaction(tx, parent, :command_gate_held)
        end)
      end)

    assert_receive {:command_gate_held, command_backend}, 3000
    request = Task.async(fn -> DeviceCommands.request(c.enc, bind.id, c.actor, "half") end)
    assert_blocked_by(c.db, command_backend)
    send(gate.pid, :release)
    assert {:ok, :released} = Task.await(gate, 3000)
    assert {:ok, :ok} = Task.await(request, 3000)

    sibling =
      Task.async(fn ->
        S.scoped(bind, fn tx, _ -> update_receipt(tx, audio, "4") end)
      end)

    heartbeat = Task.async(fn -> S.heartbeat(bind) end)
    assert {:ok, [[^audio]]} = Task.await(sibling, 3000)
    assert {:ok, :ok} = Task.await(heartbeat, 3000)

    assert {:ok,
            %{"type" => "command", "watermarks" => %{"audio" => "0", "ecg" => "0"}} = command} =
             DeviceCommands.poll(bind)

    assert [[1]] =
             S.rows(c.db, "SELECT count FROM device_heartbeats WHERE acquisition_id=$1", [bind.id])

    assert receipt_sample(c.db, audio) == "4"

    assert receipt_sample(c.db, ecg) == "0"

    revoke =
      Task.async(fn ->
        S.rows(
          c.db,
          "UPDATE device_credentials SET revoked=true WHERE device_id=$1 RETURNING device_id",
          [c.device]
        )
      end)

    assert_blocked_by(c.db, stream_backend)
    send(stalled.pid, :release)
    assert {:ok, :released} = Task.await(stalled, 3000)
    assert [[device]] = Task.await(revoke, 3000)
    assert device == c.device
    assert receipt_sample(c.db, ecg) == "13"

    result =
      command
      |> Map.take(~w(id fingerprint boot gain))
      |> Map.merge(%{"status" => "applied", "epoch" => "1", "first_sample" => "0"})

    assert {:error, :stale_lease} = DeviceCommands.result(bind, result)
    assert {:error, :stale_lease} = DeviceCommands.poll(bind)
    assert {:error, :stale_lease} = S.heartbeat(bind)
    assert {:error, :stale_lease} = S.scoped(bind, fn tx, _ -> update_receipt(tx, audio, "9") end)

    assert receipt_sample(c.db, audio) == "4"

    assert S.rows(c.db, "SELECT state,result FROM device_commands WHERE id=$1", [command["id"]]) ==
             [["dispatching", %{}]]

    assert [[1]] =
             S.rows(c.db, "SELECT count FROM device_heartbeats WHERE acquisition_id=$1", [bind.id])
  end

  test "heartbeat cannot revive an expired lease or a stale generation", c do
    assert {:ok, old} = reserve(c, "paired_exam", "expired-" <> c.enc)
    assert {:ok, bind} = reserve(c, "paired_exam", old.id)
    assert {:error, :stale_lease} = S.heartbeat(old)
    assert {:error, :stale_lease} = DeviceCommands.poll(old)
    assert {:ok, :ok} = DeviceCommands.request(c.enc, bind.id, c.actor, "half")
    assert {:ok, :ok} = S.heartbeat(bind)

    S.rows(
      c.db,
      "UPDATE device_heartbeats SET seen_at=now()-interval '61 seconds' WHERE acquisition_id=$1",
      [bind.id]
    )

    S.rows(c.db, "UPDATE device_sessions SET expires_at=now()-interval '1 second' WHERE id=$1", [
      bind.id
    ])

    assert {:error, :stale_lease} = S.heartbeat(bind)
    assert {:error, :stale_lease} = DeviceCommands.poll(bind)

    assert [[1]] =
             S.rows(c.db, "SELECT count FROM device_heartbeats WHERE acquisition_id=$1", [bind.id])

    assert [["requested"]] =
             S.rows(c.db, "SELECT state FROM device_commands WHERE acquisition_id=$1", [bind.id])
  end

  test "finalization cancels an undispatched command before reading frozen facts", c do
    assert {:ok, bind} = reserve(c, "paired_exam", "command-cancel-" <> c.enc)
    assert {:ok, :ok} = DeviceCommands.request(c.enc, bind.id, c.actor, "half")

    assert [requested, closed] = facts_at_freeze(bind)
    assert %{"type" => "command_requested", "body" => %{"id" => id}} = requested

    assert %{
             "type" => "command_cancelled_before_dispatch",
             "body" => %{"id" => ^id, "reason" => "collection_ended"}
           } = closed

    assert {:ok, %{"type" => "heartbeat"}} = DeviceCommands.poll(bind)
    assert facts_at_freeze(bind) == [requested, closed]
  end

  test "finalization freezes an unanswered dispatch as outcome unknown before readback", c do
    assert {:ok, bind} = reserve(c, "paired_exam", "command-freeze-" <> c.enc)
    assert {:ok, :ok} = DeviceCommands.request(c.enc, bind.id, c.actor, "half")
    assert {:ok, %{"type" => "command", "id" => id}} = DeviceCommands.poll(bind)

    assert [requested, dispatched, closed] = facts_at_freeze(bind)
    assert %{"type" => "command_requested", "body" => %{"id" => ^id}} = requested
    assert %{"type" => "command_dispatching", "body" => %{"id" => ^id}} = dispatched

    assert %{
             "type" => "command_outcome_unknown",
             "body" => %{"id" => ^id, "reason" => "collection_ended_without_result"}
           } = closed

    assert [[state, result, 0]] =
             S.rows(c.db, "SELECT state,result,readback_count FROM device_commands WHERE id=$1", [
               id
             ])

    assert state == "outcome_unknown"
    assert result == %{"reason" => "collection_ended_without_result"}
    assert facts_at_freeze(bind) == [requested, dispatched, closed]
  end

  defp create_attempt(db, bind, stream, number) do
    fence = S.nonce()

    S.rows(
      db,
      "INSERT INTO stream_attempts(acquisition_id,stream,number,generation,fence,receipt) VALUES($1,$2,$3,$4,$5,$6)",
      [bind.id, stream, number, bind.generation, fence, %{"durable_sample" => "0"}]
    )

    fence
  end

  defp receipt_sample(db, fence) do
    [[sample]] =
      S.rows(db, "SELECT receipt->>'durable_sample' FROM stream_attempts WHERE fence=$1", [fence])

    sample
  end

  defp update_receipt(tx, fence, sample) do
    S.rows(tx, "UPDATE stream_attempts SET receipt=$2 WHERE fence=$1 RETURNING fence", [
      fence,
      %{"durable_sample" => sample}
    ])
  end

  defp hold_transaction(tx, parent, marker) do
    [[backend]] = S.rows(tx, "SELECT pg_backend_pid()", [])
    send(parent, {marker, backend})

    receive do
      :release -> :released
    after
      15_000 -> raise "test database lock was never released"
    end
  end

  defp assert_blocked_by(db, backend) do
    assert blocked_by?(db, backend, System.monotonic_time(:millisecond) + 3000),
           "expected a PostgreSQL lock wait on backend #{backend}"
  end

  defp blocked_by?(db, backend, deadline) do
    case S.rows(
           db,
           "SELECT 1 FROM pg_stat_activity WHERE $1::int=ANY(pg_blocking_pids(pid))",
           [backend]
         ) do
      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          blocked_by?(db, backend, deadline)
        else
          false
        end

      _ ->
        true
    end
  end

  defp facts_at_freeze(bind) do
    assert {:ok, facts} =
             S.scoped(
               bind,
               fn tx, _ ->
                 S.rows(tx, "UPDATE device_sessions SET phase='finalizing' WHERE id=$1", [bind.id])

                 :ok = DeviceCommands.close_pending(tx, bind.id)
                 S.facts(tx, bind.id)
               end,
               :update
             )

    facts
  end

  defp reserve(c, profile, id), do: S.reserve(c.device, c.enc, id, profile, "boot-a", %{})
end
