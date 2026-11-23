defmodule MedFabric.Exam.EncounterScopeTest do
  use ExUnit.Case, async: true

  alias MedFabric.Exam
  alias MedFabric.Exam.Context
  alias MedFabric.Store.{Encounters, Postgres, Records}

  test "a clinician accepts only their patient's evidence and freezes that encounter's destination" do
    db = start_supervised!({Postgres, url: System.fetch_env!("DATABASE_URL")})
    {:ok, :ok} = Postgres.migrate(db)
    pubsub = __MODULE__.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    context = %Context{db: db, pubsub: pubsub}
    suffix = Base.encode16(:crypto.strong_rand_bytes(8))

    [a, b] =
      for name <- ["A", "B"] do
        id = "exam-#{name}-#{suffix}"

        entry = %{
          "exam" => id,
          "patient_actor" => "p-#{id}",
          "clinician_actor" => "c-#{id}",
          "patient_ref" => "Patient/#{id}",
          "encounter_ref" => "Encounter/#{id}",
          "destination" => "http://example.invalid/#{name}/fhir"
        }

        assert {:ok, :ok} = Encounters.open(db, entry)
        entry
      end

    Phoenix.PubSub.subscribe(pubsub, "exam:" <> b["exam"])
    assert :ok = Exam.pulse(a["exam"], a["clinician_actor"], 70, context)
    refute_received :exam_changed
    assert :ok = Exam.pulse(b["exam"], b["clinician_actor"], 80, context)
    assert_receive :exam_changed

    for {entry, other} <- [{a, b}, {b, a}] do
      id = entry["exam"]
      assert Exam.member?(id, entry["patient_actor"], "patient", db)
      assert Exam.member?(id, entry["clinician_actor"], :clinician, db)
      refute Exam.member?(id, entry["patient_actor"], "clinician", db)
      refute Exam.member?(id, entry["clinician_actor"], "unknown", db)
      assert {:error, :unauthorized} = Exam.pulse(id, entry["patient_actor"], 75, context)
      assert {:ok, [%{id: acquisition}]} = Records.list(db, id)
      assert {:error, :unauthorized} =
               Exam.accept(id, acquisition, other["clinician_actor"], context)
      assert :ok = Exam.accept(id, acquisition, entry["clinician_actor"], context)
      assert {:ok, destination, resource, nil} = Records.delivery(db, id, acquisition)
      assert destination == entry["destination"]
      assert resource["subject"]["reference"] == entry["patient_ref"]
      assert resource["encounter"]["reference"] == entry["encounter_ref"]
      assert {:error, :review_required} = Records.delivery(db, other["exam"], acquisition)
      assert {:error, :unauthorized} =
               Exam.deliver(id, acquisition, other["clinician_actor"], context)

      Postgrex.query!(db, "UPDATE encounters SET closed_at=now() WHERE id=$1", [id])
      refute Exam.member?(id, entry["clinician_actor"], :clinician, db)
      assert {:error, :unauthorized} =
               Exam.accept(id, acquisition, entry["clinician_actor"], context)
    end
  end
end
