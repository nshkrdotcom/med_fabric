# Run from apps/exam with "mix run --no-start ../../ops/seed_exam.exs".
{:ok, _} = Application.ensure_all_started(:req)
encounter = System.fetch_env!("MF_EXAM_ID")
url = System.fetch_env!("FHIR_BASE_URL")
path = System.fetch_env!("MF_REFS_FILE")
{:ok, refs} = MedFabric.Interop.FhirClient.seed_exam(encounter, base_url: url)
File.write!(path, Jason.encode!(Map.merge(refs, %{exam: encounter, destination: url})))
