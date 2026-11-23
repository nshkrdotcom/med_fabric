import Config

if System.get_env("MF_LAB") == "1" do
  refs = System.fetch_env!("MF_REFS_FILE") |> File.read!() |> Jason.decode!()
  lab = %{
    encounter_id: System.fetch_env!("MF_EXAM_ID"),
    refs: refs,
    patient_key: System.fetch_env!("MF_PATIENT_ACCESS_KEY"),
    clinician_key: System.fetch_env!("MF_CLINICIAN_ACCESS_KEY"),
    patient_actor: System.fetch_env!("MF_PATIENT_ACTOR"),
    clinician_actor: System.fetch_env!("MF_CLINICIAN_ACTOR"),
    database_url: System.fetch_env!("DATABASE_URL"),
    fhir_base_url: System.fetch_env!("FHIR_BASE_URL"),
    artifact_dir: Path.expand(System.fetch_env!("MF_ARTIFACT_DIR"))
  }

  unless refs["exam"] == lab.encounter_id and refs["destination"] == lab.fhir_base_url do
    raise "Seed references for this encounter and FHIR destination"
  end

  unless Regex.match?(~r/\A[a-zA-Z0-9-]{1,48}\z/, lab.encounter_id) do
    raise "MF_EXAM_ID must be 1–48 letters, digits, or dashes"
  end

  unless byte_size(lab.patient_key) >= 32 and byte_size(lab.clinician_key) >= 32 and
           lab.patient_key != lab.clinician_key and lab.patient_actor != lab.clinician_actor and
           lab.patient_actor != "" and lab.clinician_actor != "" do
    raise "Configure distinct patient and clinician actors and access keys of at least 32 bytes"
  end

  port = String.to_integer(System.get_env("MF_HTTP_PORT", "4000"))

  config :mf_exam, :lab, lab

  config :mf_exam, MedFabric.ExamWeb.Endpoint,
    server: true,
    check_origin: ["//localhost:#{port}", "//127.0.0.1:#{port}"],
    url: [host: "localhost", port: port],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: System.fetch_env!("MF_SECRET_KEY_BASE")
end
