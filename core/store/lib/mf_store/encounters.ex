defmodule MedFabric.Store.Encounters do
  @moduledoc "Binds each open encounter to its own participants and FHIR destination."
  alias MedFabric.Store.Records

  def open(db, entry) do
    %{"exam" => id, "patient_actor" => patient, "clinician_actor" => clinician,
      "destination" => url, "patient_ref" => patient_ref, "encounter_ref" => encounter_ref} = entry

    Postgrex.transaction(db, fn tx ->
      with :ok <- Records.open(tx, id, patient, clinician),
           %{num_rows: 1} <- Postgrex.query!(tx, """
             INSERT INTO encounter_exports AS e (encounter_id,destination,patient_ref,encounter_ref)
             VALUES ($1,$2,$3,$4) ON CONFLICT (encounter_id) DO UPDATE SET encounter_id=EXCLUDED.encounter_id
             WHERE (e.destination,e.patient_ref,e.encounter_ref) =
                   (EXCLUDED.destination,EXCLUDED.patient_ref,EXCLUDED.encounter_ref)
             """, [id, url, patient_ref, encounter_ref]) do
        :ok
      else
        _ -> Postgrex.rollback(tx, :encounter_conflict)
      end
    end)
  end

  def export(db, encounter, actor) do
    case Postgrex.query(db, """
      SELECT destination, patient_ref, encounter_ref FROM encounter_exports
      JOIN encounters ON encounters.id=encounter_exports.encounter_id
      WHERE encounters.id=$1 AND clinician_actor=$2 AND closed_at IS NULL
      """, [encounter, actor]) do
      {:ok, %{rows: [[url, p, e]]}} -> {:ok, url, %{"patient_ref" => p, "encounter_ref" => e}}
      {:ok, %{rows: []}} -> {:error, :unauthorized}
      error -> error
    end
  end
end
