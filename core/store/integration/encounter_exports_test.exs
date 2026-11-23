defmodule MedFabric.Store.EncounterExportsTest do
  use ExUnit.Case
  alias MedFabric.Store.{Encounters, Postgres}

  test "two live encounters retain independent members and frozen export references" do
    db = start_supervised!({Postgres, url: System.fetch_env!("DATABASE_URL")})
    {:ok, :ok} = Postgres.migrate(db)
    group = Base.encode16(:crypto.strong_rand_bytes(8))

    [a, b] = for n <- 1..2 do
      id = "scope-#{group}-#{n}"
      entry = %{
        "exam" => id, "patient_actor" => "p-#{id}", "clinician_actor" => "c-#{id}",
        "patient_ref" => "Patient/#{id}", "encounter_ref" => "Encounter/#{id}",
        "destination" => "http://example.invalid/fhir"
      }
      assert {:ok, :ok} = Encounters.open(db, entry)
      entry
    end

    for {own, other} <- [{a, b}, {b, a}] do
      assert {:ok, _url, refs} = Encounters.export(db, own["exam"], own["clinician_actor"])
      assert refs == Map.take(own, ["patient_ref", "encounter_ref"])
      assert {:error, :unauthorized} = Encounters.export(db, own["exam"], other["clinician_actor"])
    end

    assert {:error, :encounter_conflict} = Encounters.open(db, %{a | "patient_ref" => b["patient_ref"]})
  end
end
