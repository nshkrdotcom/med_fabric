# Run from the configured private admin environment after fresh schema initialization.
{opts, [], []} =
  OptionParser.parse(System.argv(), strict: [device: :string, credential_file: :string])

{:ok, _} = Application.ensure_all_started(:postgrex)

{:ok, db} =
  MedFabric.Store.Postgres.start_link(url: System.fetch_env!("DATABASE_URL"))

deployment_uuid = System.fetch_env!("MF_DEPLOYMENT_UUID")

{:ok, %{deployment_uuid: ^deployment_uuid, revision: 2, recovery_state: "current"}} =
  MedFabric.Store.Postgres.identity(db)

id = Keyword.fetch!(opts, :device)
unless Regex.match?(~r/\A[A-Za-z0-9_-]{1,96}\z/, id), do: raise("invalid enrollment identity")
token = File.read!(Keyword.fetch!(opts, :credential_file)) |> String.trim()
true = MedFabric.Store.DeviceSessions.enroll(db, id, token)
IO.puts("Device enrolled. A clinician must grant an encounter and profile before collection.")
