defmodule MedFabric.Exam.EncounterScopeTest do
  use ExUnit.Case, async: false

  alias MedFabric.Exam
  alias MedFabric.Store.{Encounters, Postgres, Records}

  test "a clinician accepts only their patient's evidence and freezes that encounter's destination" do
    start_supervised!({Postgres, url: System.fetch_env!("DATABASE_URL"), name: Postgres})
    {:ok, :ok} = Postgres.migrate()
    suffix = Base.encode16(:crypto.strong_rand_bytes(8))
    previous = Application.get_env(:mf_exam, :lab)
    Application.put_env(:mf_exam, :lab, %{artifact_dir: ""})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mf_exam, :lab, previous),
        else: Application.delete_env(:mf_exam, :lab)
    end)

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

        assert {:ok, :ok} = Encounters.open(Postgres, entry)
        entry
      end

    Phoenix.PubSub.subscribe(Exam.PubSub, "exam:" <> b["exam"])
    assert :ok = Exam.pulse(a["exam"], a["clinician_actor"], 70)
    refute_received :exam_changed
    assert :ok = Exam.pulse(b["exam"], b["clinician_actor"], 80)
    assert_receive :exam_changed

    for {entry, other} <- [{a, b}, {b, a}] do
      id = entry["exam"]
      assert {:ok, [%{id: acquisition}]} = Records.list(Postgres, id)
      assert {:error, :unauthorized} = Exam.accept(id, acquisition, other["clinician_actor"])
      assert :ok = Exam.accept(id, acquisition, entry["clinician_actor"])
      assert {:ok, destination, resource, nil} = Records.delivery(Postgres, id, acquisition)
      assert destination == entry["destination"]
      assert resource["subject"]["reference"] == entry["patient_ref"]
      assert resource["encounter"]["reference"] == entry["encounter_ref"]
      assert {:error, :review_required} = Records.delivery(Postgres, other["exam"], acquisition)
    end
  end
end
