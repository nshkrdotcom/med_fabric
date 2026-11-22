import Config

if System.get_env("MF_LAB") == "1" do
  lab = %{
    encounter_id: System.fetch_env!("MF_EXAM_ID"),
    access_key: System.fetch_env!("MF_LAB_ACCESS_KEY"),
    database_url: System.fetch_env!("DATABASE_URL"),
    fhir_base_url: System.fetch_env!("FHIR_BASE_URL"),
    fixture_dir: Path.expand(System.fetch_env!("MF_FIXTURE_DIR")),
    artifact_dir: Path.expand(System.fetch_env!("MF_ARTIFACT_DIR"))
  }

  unless Regex.match?(~r/\A[a-zA-Z0-9-]{1,48}\z/, lab.encounter_id) do
    raise "MF_EXAM_ID must be 1–48 letters, digits, or dashes"
  end

  if byte_size(lab.access_key) < 32, do: raise("MF_LAB_ACCESS_KEY must contain at least 32 bytes")

  port = String.to_integer(System.get_env("MF_HTTP_PORT", "4000"))

  config :mf_exam, :lab, lab

  config :mf_exam, MedFabric.ExamWeb.Endpoint,
    server: true,
    check_origin: ["//localhost:#{port}", "//127.0.0.1:#{port}"],
    url: [host: "localhost", port: port],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: System.fetch_env!("MF_SECRET_KEY_BASE")
end
