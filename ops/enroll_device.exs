# Run from the configured private admin environment after schema migration.
{opts, [], []} =
  OptionParser.parse(System.argv(), strict: [device: :string, credential_file: :string])

{:ok, _} = Application.ensure_all_started(:postgrex)

{:ok, _} =
  MedFabric.Store.Postgres.start_link(
    url: System.fetch_env!("DATABASE_URL"),
    name: MedFabric.Store.Postgres
  )

id = Keyword.fetch!(opts, :device)
unless Regex.match?(~r/\A[A-Za-z0-9_-]{1,96}\z/, id), do: raise("invalid enrollment identity")
token = File.read!(Keyword.fetch!(opts, :credential_file)) |> String.trim()
true = MedFabric.Store.DeviceSessions.enroll(id, token)
IO.puts("Device enrolled. A clinician must grant an encounter and profile before collection.")
