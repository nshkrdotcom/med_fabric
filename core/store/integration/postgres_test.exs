Code.require_file("support/fixture.exs", __DIR__)

defmodule MedFabric.Store.PostgresTest do
  use ExUnit.Case, async: false
  alias MedFabric.Domain.Review
  alias MedFabric.Store.{AcquisitionSessions, Encounters, Postgres, Records}
  alias MedFabric.Store.IntegrationFixture, as: F

  setup do
    fixture = F.database()
    F.encounter(fixture.db)
    source = F.manual(fixture.db)
    {:ok, plan} = Review.plan(source, "clinician", "accept_request", %{"decision" => "accept"}, ~U[2026-11-24 12:00:01Z])
    Map.merge(fixture, %{source: source, plan: plan})
  end

  test "concurrent retries commit exactly one native decision, observation and unprepared intent", c do
    tasks = for _ <- 1..4, do: Task.async(fn -> Records.accept_plan(c.db, c.plan) end)
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert [{:ok, outcome}] = Enum.uniq(results)
    assert [observation] = outcome.observations
    assert [[1, 1, 1]] = AcquisitionSessions.rows(c.db,
      "SELECT (SELECT count(*) FROM reviews),(SELECT count(*) FROM observations),(SELECT count(*) FROM outbox_deliveries)", [])
    assert [["pending", nil, nil, "urn:uuid:" <> namespace, ^observation]] = AcquisitionSessions.rows(c.db,
      "SELECT status,destination,resource,identifier_system,identifier_value FROM outbox_deliveries WHERE id=$1", [observation])
    assert namespace == c.uuid
    assert {:error, :destination_missing} = Encounters.export(c.db, "encounter")
    assert {:ok, entries} = Records.list(c.db, "encounter", "clinician")
    assert [%{decision: decision, observation: ^observation, status: "pending"}] = entries
    assert decision == outcome.decision_id
  end

  test "rollback removes the whole clinical transaction while preserving entered manual evidence", c do
    assert {:error, :rollback_check} = Postgrex.transaction(c.db, fn tx ->
      assert {:ok, %{observations: [_]}} = Records.accept_plan(tx, c.plan)
      Postgrex.rollback(tx, :rollback_check)
    end)
    assert [[0, 0, 0, 1]] = AcquisitionSessions.rows(c.db,
      "SELECT (SELECT count(*) FROM reviews),(SELECT count(*) FROM observations),(SELECT count(*) FROM outbox_deliveries),(SELECT count(*) FROM manual_evidence)", [])
    assert {:ok, %{observations: [_]}} = Records.accept_plan(c.db, c.plan)
  end

  test "exact committed request replays after closure and a fresh timestamp cannot change its identity", c do
    assert {:ok, original} = Records.accept_plan(c.db, c.plan)
    assert {:ok, :ok} = Encounters.close(c.db, "encounter", "clinician")
    {:ok, later} = Review.plan(c.source, "clinician", "accept_request", %{"decision" => "accept"}, ~U[2026-11-25 12:00:01Z])
    assert later.request == c.plan.request and later.decided_at != c.plan.decided_at
    assert {:ok, ^original} = Records.accept_plan(c.db, later)
    {:ok, changed} = Review.plan(c.source, "clinician", "accept_request", %{"decision" => "reject"}, ~U[2026-11-25 12:00:01Z])
    assert {:error, :request_conflict} = Records.accept_plan(c.db, changed)
    {:ok, fresh} = Review.plan(c.source, "clinician", "another_request", %{"decision" => "accept"}, ~U[2026-11-25 12:00:01Z])
    assert {:error, :unauthorized} = Records.accept_plan(c.db, fresh)
    assert Records.member?(c.db, "encounter", "clinician", :clinician, :read)
    refute Records.member?(c.db, "encounter", "clinician", :clinician, :mutate)
  end

  test "different competing request identities cannot create a second decision", c do
    {:ok, other} = Review.plan(c.source, "clinician", "competing_request", %{"decision" => "reject"}, ~U[2026-11-24 12:00:02Z])
    results = [c.plan, other] |> Enum.map(fn plan -> Task.async(fn -> Records.accept_plan(c.db, plan) end) end) |> Enum.map(&Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :review_conflict})) == 1
    assert [[1]] = AcquisitionSessions.rows(c.db, "SELECT count(*) FROM reviews", [])
    assert_raise Postgrex.Error, fn -> AcquisitionSessions.rows(c.db, "UPDATE manual_evidence SET digest=$1", [String.duplicate("a", 64)]) end
    assert_raise Postgrex.Error, fn -> AcquisitionSessions.rows(c.db, "DELETE FROM reviews", []) end
  end

  test "acceptance first holds the encounter lock until all native rows commit, then closure is replay safe", c do
    parent = self()
    acceptance = Task.async(fn -> Postgrex.transaction(c.db, fn tx ->
      assert {:ok, outcome} = Records.accept_plan(tx, c.plan)
      send(parent, {:acceptance_locked, Postgres.backend_id(tx)})
      receive do :release -> outcome after 10_000 -> raise "acceptance barrier was not released" end
    end) end)
    assert_receive {:acceptance_locked, backend}, 3000
    close = Task.async(fn -> Encounters.close(c.db, "encounter", "clinician") end)
    assert F.blocked_by?(c.db, backend)
    send(acceptance.pid, :release)
    assert {:ok, outcome} = Task.await(acceptance, 10_000)
    assert {:ok, :ok} = Task.await(close, 10_000)
    assert {:ok, ^outcome} = Records.accept_plan(c.db, c.plan)
  end

  test "closure first prevents every row of a competing new acceptance", c do
    parent = self()
    close = Task.async(fn -> Postgrex.transaction(c.db, fn tx ->
      assert {:ok, :ok} = Encounters.close(tx, "encounter", "clinician")
      send(parent, {:closure_locked, Postgres.backend_id(tx)})
      receive do :release -> :ok after 10_000 -> raise "closure barrier was not released" end
    end) end)
    assert_receive {:closure_locked, backend}, 3000
    acceptance = Task.async(fn -> Records.accept_plan(c.db, c.plan) end)
    assert F.blocked_by?(c.db, backend)
    send(close.pid, :release)
    assert {:ok, :ok} = Task.await(close, 10_000)
    assert {:error, :unauthorized} = Task.await(acceptance, 10_000)
    assert [[0, 0, 0]] = AcquisitionSessions.rows(c.db,
      "SELECT (SELECT count(*) FROM reviews),(SELECT count(*) FROM observations),(SELECT count(*) FROM outbox_deliveries)", [])
  end

  test "explicit independent pools cannot read or mutate each other's namespace", c do
    second = F.database()
    F.encounter(second.db)
    other_source = F.manual(second.db, "manual", 81)
    assert c.db != second.db and c.schema != second.schema and c.uuid != second.uuid
    assert {:ok, %{observations: [_]}} = Records.accept_plan(c.db, c.plan)
    assert {:ok, ^other_source} = Records.manual(second.db, "encounter", "manual", "clinician")
    assert [[0, 0]] = AcquisitionSessions.rows(second.db, "SELECT (SELECT count(*) FROM reviews),(SELECT count(*) FROM outbox_deliveries)", [])
    assert {:ok, %{deployment_uuid: uuid}} = Postgres.identity(second.db)
    assert uuid == second.uuid
  end
end
