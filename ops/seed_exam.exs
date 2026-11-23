Code.require_file("lab_fhir.exs", __DIR__)
{:ok, _} = Application.ensure_all_started(:req)
encounter = System.fetch_env!("MF_EXAM_ID")
url = System.fetch_env!("FHIR_BASE_URL")
path = System.fetch_env!("MF_ENCOUNTERS_FILE")
{:ok, refs} = MedFabric.LabFHIR.seed_exam(encounter, base_url: url)

entry = %{
  "exam" => encounter,
  "patient_actor" => System.fetch_env!("MF_PATIENT_ACTOR"),
  "clinician_actor" => System.fetch_env!("MF_CLINICIAN_ACTOR"),
  "patient_key" => System.fetch_env!("MF_PATIENT_ACCESS_KEY"),
  "clinician_key" => System.fetch_env!("MF_CLINICIAN_ACCESS_KEY"),
  "destination" => url,
  "patient_ref" => refs.patient_ref,
  "encounter_ref" => refs.encounter_ref
}

existing =
  case File.read(path) do
    {:ok, bytes} -> Jason.decode!(bytes)
    {:error, :enoent} -> []
    {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
  end

tmp = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)

File.open!(tmp, [:exclusive, :write], fn io ->
  File.chmod!(tmp, 0o600)
  IO.binwrite(io, Jason.encode!([entry | Enum.reject(existing, &(&1["exam"] == encounter))]))
end)

File.rename!(tmp, path)
