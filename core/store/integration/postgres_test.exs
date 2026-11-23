defmodule MedFabric.Store.PostgresTest do
  use ExUnit.Case
  alias MedFabric.Domain.Evidence
  alias MedFabric.Store.{Postgres, Records}

  setup do
    db = start_supervised!({Postgres, url: System.fetch_env!("DATABASE_URL"), pool_size: 3})
    {:ok, :ok} = Postgres.migrate(db)
    encounter = "pg-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    :ok = Records.open(db, encounter, "patient", "clinician")
    {:ok, evidence} = Evidence.pulse_rate(70, DateTime.utc_now(), "clinician")
    :ok = Records.ready(db, encounter, "pulse", evidence)
    %{db: db, encounter: encounter, evidence: evidence}
  end

  test "concurrent acceptance is atomic and late evidence cannot supersede it", c do
    accept = fn ->
      Records.accept(c.db, c.encounter, "pulse", "clinician", c.evidence, "fhir", c.encounter, %{})
    end

    first = Task.async(accept)
    second = Task.async(accept)
    assert {:ok, :ok} = Task.await(first)
    assert {:ok, :ok} = Task.await(second)
    assert {:ok, "fhir", %{}, nil} = Records.delivery(c.db, c.encounter, "pulse")

    assert {:error, :evidence_conflict} =
             Records.ready(c.db, c.encounter, "pulse", Map.put(c.evidence, "value", 71))

    evidence = c.evidence
    assert {:ok, [%{conflict: false, actor: "clinician", evidence: ^evidence}]} =
             Records.list(c.db, c.encounter)
  end

  test "rolling back acceptance rolls back its outbox", c do
    assert {:error, :rollback_check} =
             Postgrex.transaction(c.db, fn tx ->
               assert {:ok, :ok} =
                        Records.accept(tx, c.encounter, "pulse", "clinician", c.evidence,
                          "fhir", c.encounter, %{})

               Postgrex.rollback(tx, :rollback_check)
             end)

    assert {:ok, [%{actor: nil}]} = Records.list(c.db, c.encounter)
    assert {:error, :review_required} = Records.delivery(c.db, c.encounter, "pulse")
  end
end
