Code.require_file("support/fixture.exs", __DIR__)

defmodule MedFabric.Store.DeviceAdmissionTest do
  use ExUnit.Case, async: false
  alias MedEx.Serialization

  alias MedFabric.Store.{
    AcquisitionSessions,
    DeviceCommands,
    DeviceSessions,
    Encounters,
    MeasurementEvents,
    Postgres
  }

  alias MedFabric.Store.IntegrationFixture, as: F

  setup do
    fixture = F.database()
    F.encounter(fixture.db)
    principal = F.device(fixture.db)
    Map.put(fixture, :principal, principal)
  end

  test "fresh schema bootstrap is idempotent under concurrent startup and preserves native identity",
       c do
    tasks = for _ <- 1..2, do: Task.async(fn -> Postgres.migrate(c.db, c.uuid) end)
    assert Enum.map(tasks, &Task.await(&1, 10_000)) == [{:ok, :ok}, {:ok, :ok}]

    assert {:ok, %{deployment_uuid: uuid, revision: 2, recovery_state: "current"}} =
             Postgres.identity(c.db)

    assert uuid == c.uuid
    assert {:ok, "gateway"} = DeviceSessions.authenticate(c.db, String.duplicate("t", 48))
    assert {:error, :denied} = DeviceSessions.authenticate(c.db, String.duplicate("x", 48))

    assert {:error, :incompatible_deployment} =
             Postgres.migrate(c.db, "00000000-0000-4000-8000-000000000099")

    assert [["acquisition_sessions"]] =
             AcquisitionSessions.rows(
               c.db,
               "SELECT tablename FROM pg_tables WHERE schemaname=current_schema() AND tablename='acquisition_sessions'",
               []
             )

    assert [] =
             AcquisitionSessions.rows(
               c.db,
               "SELECT tablename FROM pg_tables WHERE schemaname=current_schema() AND tablename IN ('mf_schema_history','device_sessions','captures')",
               []
             )
  end

  test "paired, PLX and browser profiles coexist while same-profile admission remains exclusive",
       c do
    assert {:ok, paired} =
             AcquisitionSessions.admit(c.db, c.principal, F.hello("paired_exam", "paired"))

    assert {:ok, plx} =
             AcquisitionSessions.admit(c.db, c.principal, F.hello("plx_spot_check", "plx"))

    assert {:ok, :ok} =
             Encounters.browser_session(c.db, "patient_session", "encounter", "patient", :patient)

    assert {:ok, creation} =
             AcquisitionSessions.create_browser(
               c.db,
               "encounter",
               "patient",
               "patient_session",
               "page",
               "create_request"
             )

    browser_hello =
      F.hello("browser_microphone", creation.acquisition, "page", "patient")
      |> Map.put("creation", creation.creation)

    assert {:ok, browser} =
             AcquisitionSessions.admit(
               c.db,
               %{kind: :browser, id: "patient", session: "patient_session"},
               browser_hello
             )

    assert length(Enum.uniq([paired.id, plx.id, browser.id])) == 3

    tasks =
      for id <- ["competing_one", "competing_two"],
          do:
            Task.async(fn ->
              AcquisitionSessions.admit(c.db, c.principal, F.hello("paired_exam", id))
            end)

    assert Enum.map(tasks, &Task.await(&1, 10_000)) == [
             {:error, :active_profile_busy},
             {:error, :active_profile_busy}
           ]

    assert {:ok, :ok} =
             AcquisitionSessions.freeze(c.db, paired, %{}, %{"fixture" => "explicit_clock"})

    assert {:error, :active_profile_busy} =
             AcquisitionSessions.admit(
               c.db,
               c.principal,
               F.hello("paired_exam", "during_finalization")
             )
  end

  test "generation rotation invalidates old admission, descriptor boot mismatch and changed source are refused",
       c do
    hello = F.hello()
    assert {:ok, old} = AcquisitionSessions.admit(c.db, c.principal, hello)
    assert {:ok, current} = AcquisitionSessions.admit(c.db, c.principal, hello)

    assert current.generation == old.generation + 1 and current.lease != old.lease and
             current.connection != old.connection

    assert {:error, :stale_binding} =
             AcquisitionSessions.scoped(c.db, old, fn _, _ ->
               flunk("obsolete binding executed")
             end)

    assert {:ok, :current} = AcquisitionSessions.scoped(c.db, current, fn _, _ -> :current end)

    assert {:error, :immutable_source_changed} =
             AcquisitionSessions.admit(
               c.db,
               c.principal,
               F.hello("paired_exam", "acquisition", "different_boot")
             )

    mismatched =
      put_in(
        hello,
        ["descriptors", "audio"],
        Serialization.to_map(F.spec("audio", "acquisition", "gateway", "different_boot"))
      )

    assert {:error, :invalid_hello} = AcquisitionSessions.admit(c.db, c.principal, mismatched)

    assert {:error, :unauthorized} =
             DeviceSessions.authorize(
               c.db,
               "encounter",
               "gateway",
               "paired_exam",
               "site",
               "other_actor"
             )

    assert {:ok, :ok} =
             DeviceSessions.revoke(c.db, "encounter", "gateway", "paired_exam", "clinician")

    assert {:error, :stale_binding} =
             AcquisitionSessions.scoped(c.db, current, fn _, _ ->
               flunk("revoked binding executed")
             end)

    assert {:error, :grant_denied} = AcquisitionSessions.admit(c.db, c.principal, hello)
  end

  test "admission near maximum lifetime grants only the remaining server authority", c do
    hello = F.hello()
    # Maximum lifetime is immutable source identity. Model a previously created
    # short-lived source at INSERT, without disabling or bypassing that guard.
    assert {:ok, :ok} =
             Postgrex.transaction(c.db, fn tx ->
               AcquisitionSessions.rows(
                 tx,
                 "INSERT INTO acquisitions(id,encounter_id,source_kind,principal,profile,state) VALUES($1,$2,'device',$3,$4,'capturing')",
                 [hello["acquisition"], hello["encounter"], c.principal.id, hello["profile"]]
               )

               AcquisitionSessions.rows(
                 tx,
                 "INSERT INTO acquisition_sessions(id,encounter_id,source_kind,principal,profile,device_id,boot,site,descriptors,lease_hash,expires_at,maximum_at) VALUES($1,$2,'device',$3,$4,$3,$5,$6,$7,$8,clock_timestamp()+interval '2 seconds',clock_timestamp()+interval '2 seconds')",
                 [
                   hello["acquisition"],
                   hello["encounter"],
                   c.principal.id,
                   hello["profile"],
                   hello["boot"],
                   "Synthetic anterior site",
                   hello["descriptors"],
                   AcquisitionSessions.hash("initial_fixture_lease")
                 ]
               )

               :ok
             end)

    assert {:ok, resumed} = AcquisitionSessions.admit(c.db, c.principal, hello)
    assert resumed.authority_ms in 1..2000

    AcquisitionSessions.rows(
      c.db,
      "UPDATE acquisition_sessions SET expires_at=clock_timestamp()-interval '1 second' WHERE id=$1",
      [resumed.id]
    )

    assert {:error, :stale_binding} = AcquisitionSessions.heartbeat(c.db, resumed, "expired_poll")
    assert {:error, :stale_binding} = DeviceCommands.poll(c.db, resumed, "expired_command_poll")
  end

  test "a quiescent used fence needs a new admission generation before another writable attempt",
       c do
    hello = F.hello()
    {:ok, bind} = AcquisitionSessions.admit(c.db, c.principal, hello)

    assert {:ok, first} =
             AcquisitionSessions.scoped(
               c.db,
               bind,
               fn tx, s -> AcquisitionSessions.reserve_attempt(tx, s, "audio") end,
               :update
             )

    assert {:ok, ^first} =
             AcquisitionSessions.scoped(
               c.db,
               bind,
               fn tx, s -> AcquisitionSessions.reserve_attempt(tx, s, "audio") end,
               :update
             )

    assert {:ok, _} =
             AcquisitionSessions.scoped(
               c.db,
               bind,
               fn tx, _ -> AcquisitionSessions.mark_attempt(tx, first.fence, "quiescent") end,
               :update
             )

    assert {:error, :readmission_required} =
             AcquisitionSessions.scoped(
               c.db,
               bind,
               fn tx, s -> AcquisitionSessions.reserve_attempt(tx, s, "audio") end,
               :update
             )

    {:ok, next_bind} = AcquisitionSessions.admit(c.db, c.principal, hello)

    assert {:ok, next} =
             AcquisitionSessions.scoped(
               c.db,
               next_bind,
               fn tx, s -> AcquisitionSessions.reserve_attempt(tx, s, "audio") end,
               :update
             )

    assert next.fence != first.fence and next.generation == first.generation + 1
  end

  test "shared admission scope and rotation follow encounter-first exclusion without grant lock inversion",
       c do
    hello = F.hello()
    {:ok, bind} = AcquisitionSessions.admit(c.db, c.principal, hello)
    parent = self()

    holder =
      Task.async(fn ->
        AcquisitionSessions.scoped(c.db, bind, fn tx, _ ->
          send(parent, {:admission_locked, Postgres.backend_id(tx)})

          receive do
            :read_grant ->
              AcquisitionSessions.rows(
                tx,
                "SELECT site FROM device_grants WHERE encounter_id='encounter' AND device_id='gateway' AND profile='paired_exam' FOR SHARE",
                []
              )
          after
            10_000 -> raise "admission barrier was not released"
          end
        end)
      end)

    assert_receive {:admission_locked, backend}, 3000
    rotation = Task.async(fn -> AcquisitionSessions.admit(c.db, c.principal, hello) end)
    assert F.blocked_by?(c.db, backend)
    send(holder.pid, :read_grant)
    assert {:ok, [["Synthetic anterior site"]]} = Task.await(holder, 10_000)
    assert {:ok, rotated} = Task.await(rotation, 10_000)
    assert rotated.generation == bind.generation + 1

    assert {:error, :stale_binding} =
             AcquisitionSessions.scoped(c.db, bind, fn _, _ -> :obsolete end)
  end

  test "heartbeat and command exchange progress during a stalled admitted effect while revoke waits",
       c do
    {:ok, bind} = AcquisitionSessions.admit(c.db, c.principal, F.hello())
    parent = self()

    effect =
      Task.async(fn ->
        AcquisitionSessions.scoped(c.db, bind, fn tx, _ ->
          send(parent, {:effect_locked, Postgres.backend_id(tx)})

          receive do
            :release -> :settled
          after
            10_000 -> raise "effect barrier was not released"
          end
        end)
      end)

    assert_receive {:effect_locked, backend}, 3000
    heartbeat = Task.async(fn -> AcquisitionSessions.heartbeat(c.db, bind, "during_effect") end)
    assert {:ok, %{nonce: "during_effect", remaining_ms: remaining}} = Task.await(heartbeat, 3000)
    assert remaining in 1..30_000

    request =
      Task.async(fn ->
        DeviceCommands.request(c.db, "encounter", bind.id, "clinician", "half")
      end)

    assert {:ok, :ok} = Task.await(request, 3000)
    poll = Task.async(fn -> DeviceCommands.poll(c.db, bind, "command_during_effect") end)
    assert {:ok, %{"type" => "command", "command" => command}} = Task.await(poll, 3000)
    result = Task.async(fn -> DeviceCommands.result(c.db, bind, F.applied(command)) end)
    assert {:ok, :ok} = Task.await(result, 3000)

    revoke =
      Task.async(fn ->
        DeviceSessions.revoke(c.db, "encounter", "gateway", "paired_exam", "clinician")
      end)

    assert F.blocked_by?(c.db, backend)
    send(effect.pid, :release)
    assert {:ok, :settled} = Task.await(effect, 10_000)
    assert {:ok, :ok} = Task.await(revoke, 10_000)
    assert {:error, :stale_binding} = AcquisitionSessions.heartbeat(c.db, bind, "after_revoke")
    assert {:error, :stale_binding} = DeviceCommands.poll(c.db, bind, "after_revoke")
    assert {:error, :stale_binding} = DeviceCommands.result(c.db, bind, F.applied(command))

    assert [["applied"]] =
             AcquisitionSessions.rows(c.db, "SELECT state FROM device_commands WHERE id=$1", [
               command["id"]
             ])
  end

  test "typed PLX events replay exactly and conflicting identities cannot alter the frozen inventory",
       c do
    {:ok, bind} = AcquisitionSessions.admit(c.db, c.principal, F.hello("plx_spot_check", "plx"))
    event = F.event(bind.id)
    assert {:ok, ack} = MeasurementEvents.put(c.db, bind, event)
    assert ack.event_id == event["event_id"] and ack.fingerprint == Serialization.digest(event)
    assert {:ok, ^ack} = MeasurementEvents.put(c.db, bind, event)

    assert {:error, :event_conflict} =
             MeasurementEvents.put(c.db, bind, F.event(bind.id, "event_one", 0, 730))

    assert {:error, :event_conflict} =
             MeasurementEvents.put(c.db, bind, F.event(bind.id, "other_id", 0))

    final = %{
      "count" => "1",
      "digest" => Serialization.digest([[event["event_id"], ack.fingerprint]])
    }

    assert {:ok, :ok} =
             AcquisitionSessions.freeze(c.db, bind, final, %{"fixture" => "explicit_clock"})

    assert {:ok, ^ack} = MeasurementEvents.put(c.db, bind, event)

    assert {:error, :inventory_conflict} =
             MeasurementEvents.put(c.db, bind, F.event(bind.id, "late_event", 1))

    assert [[1]] = AcquisitionSessions.rows(c.db, "SELECT count(*) FROM measurement_events", [])

    assert_raise Postgrex.Error, fn ->
      AcquisitionSessions.rows(c.db, "DELETE FROM measurement_events", [])
    end
  end

  test "timed-out command requires exact historical application and preserves an unknown sample boundary",
       c do
    {:ok, bind} = AcquisitionSessions.admit(c.db, c.principal, F.hello())
    assert {:ok, :ok} = DeviceCommands.request(c.db, "encounter", bind.id, "clinician", "half")

    assert {:ok,
            %{
              "type" => "command",
              "nonce" => "first_poll",
              "command" => command,
              "command_remaining_ms" => remaining
            }} = DeviceCommands.poll(c.db, bind, "first_poll")

    assert remaining in 1..30_000
    assert command["boot"] == bind.boot and command["generation"] == to_string(bind.generation)

    assert {:error, :reconciliation_required} =
             DeviceCommands.request(c.db, "encounter", bind.id, "clinician", "unity")

    AcquisitionSessions.rows(
      c.db,
      "UPDATE device_commands SET updated_at=clock_timestamp()-interval '4 seconds' WHERE id=$1",
      [command["id"]]
    )

    assert {:ok, %{"type" => "state_query", "id" => id}} =
             DeviceCommands.poll(c.db, bind, "readback_poll")

    assert id == command["id"]

    assert {:error, :command_conflict} =
             DeviceCommands.result(c.db, bind, %{
               "id" => id,
               "gain" => "half",
               "expected_epoch" => "0",
               "epoch" => "1",
               "status" => "applied"
             })

    result = F.applied(command, "unknown")

    for {key, value} <- [
          {"fingerprint", String.duplicate("f", 64)},
          {"boot", "another_boot"},
          {"target", "raw_source"},
          {"generation", "0"},
          {"epoch", "2"}
        ] do
      assert {:error, :command_conflict} =
               DeviceCommands.result(c.db, bind, Map.put(result, key, value))
    end

    assert {:ok, :ok} = DeviceCommands.result(c.db, bind, result)
    assert {:ok, :ok} = DeviceCommands.result(c.db, bind, result)

    assert [["applied", ^result]] =
             AcquisitionSessions.rows(
               c.db,
               "SELECT state,result FROM device_commands WHERE id=$1",
               [id]
             )

    assert [
             ["command_requested"],
             ["command_dispatching"],
             ["command_outcome_unknown"],
             ["command_applied"]
           ] =
             AcquisitionSessions.rows(
               c.db,
               "SELECT kind FROM acquisition_facts WHERE acquisition_id=$1 ORDER BY ordinal",
               [bind.id]
             )

    assert {:ok, :ok} = DeviceCommands.request(c.db, "encounter", bind.id, "clinician", "unity")

    assert {:ok, %{"command" => %{"expected_epoch" => "1"}}} =
             DeviceCommands.poll(c.db, bind, "next_poll")
  end

  test "expired requested command is known rejected and readback attempts remain bounded", c do
    {:ok, bind} = AcquisitionSessions.admit(c.db, c.principal, F.hello())
    assert {:ok, :ok} = DeviceCommands.request(c.db, "encounter", bind.id, "clinician", "half")

    AcquisitionSessions.rows(
      c.db,
      "UPDATE device_commands SET expires_at=clock_timestamp()-interval '1 second' WHERE acquisition_id=$1",
      [bind.id]
    )

    assert {:ok, %{"type" => "heartbeat_reply"}} =
             DeviceCommands.poll(c.db, bind, "expired_request")

    assert [["rejected", %{"reason" => "expired_before_dispatch"}]] =
             AcquisitionSessions.rows(c.db, "SELECT state,result FROM device_commands", [])

    assert {:ok, :ok} = DeviceCommands.request(c.db, "encounter", bind.id, "clinician", "unity")
    {:ok, %{"command" => command}} = DeviceCommands.poll(c.db, bind, "dispatch")

    AcquisitionSessions.rows(
      c.db,
      "UPDATE device_commands SET updated_at=clock_timestamp()-interval '4 seconds' WHERE id=$1",
      [command["id"]]
    )

    assert {:ok, %{"type" => "state_query"}} = DeviceCommands.poll(c.db, bind, "timeout")

    for n <- 1..3 do
      AcquisitionSessions.rows(
        c.db,
        "UPDATE device_commands SET updated_at=clock_timestamp()-interval '2 seconds' WHERE id=$1",
        [command["id"]]
      )

      assert {:ok, %{"type" => "state_query"}} = DeviceCommands.poll(c.db, bind, "query_#{n}")
    end

    AcquisitionSessions.rows(
      c.db,
      "UPDATE device_commands SET updated_at=clock_timestamp()-interval '2 seconds' WHERE id=$1",
      [command["id"]]
    )

    assert {:ok, %{"type" => "heartbeat_reply"}} =
             DeviceCommands.poll(c.db, bind, "query_exhausted")

    assert [[3, "outcome_unknown"]] =
             AcquisitionSessions.rows(
               c.db,
               "SELECT readback_count,state FROM device_commands WHERE id=$1",
               [command["id"]]
             )
  end

  test "freeze records undispatched rejection or dispatched unknown exactly once and refuses late result",
       c do
    for dispatched? <- [false, true] do
      # Separate fixture namespace permits the same profile while retaining
      # both immutable source histories and exercising the public Store path.
      local = if dispatched?, do: F.database(), else: c

      if dispatched? do
        F.encounter(local.db)
        F.device(local.db)
      end

      {:ok, bind} = AcquisitionSessions.admit(local.db, c.principal, F.hello())

      assert {:ok, :ok} =
               DeviceCommands.request(local.db, "encounter", bind.id, "clinician", "half")

      command =
        if dispatched? do
          {:ok, %{"command" => command}} = DeviceCommands.poll(local.db, bind, "dispatch")
          command
        end

      assert {:ok, :ok} =
               AcquisitionSessions.freeze(local.db, bind, %{}, %{"fixture" => "explicit_clock"})

      {:ok, before} =
        AcquisitionSessions.settlement(local.db, bind.id, fn tx, _ ->
          AcquisitionSessions.facts(tx, bind.id)
        end)

      assert {:ok, :ok} =
               AcquisitionSessions.freeze(local.db, bind, %{}, %{
                 "fixture" => "ignored_on_exact_retry"
               })

      {:ok, after_retry} =
        AcquisitionSessions.settlement(local.db, bind.id, fn tx, _ ->
          AcquisitionSessions.facts(tx, bind.id)
        end)

      assert after_retry == before
      expected = if dispatched?, do: "outcome_unknown", else: "rejected"

      assert [[^expected]] =
               AcquisitionSessions.rows(local.db, "SELECT state FROM device_commands", [])

      if command,
        do:
          assert(
            {:error, :frozen_evidence} = DeviceCommands.result(local.db, bind, F.applied(command))
          )

      assert {:error, :inactive} =
               DeviceCommands.request(local.db, "encounter", bind.id, "clinician", "unity")
    end
  end
end
