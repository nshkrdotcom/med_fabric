Postgrex.Types.define(MedFabric.Store.Postgres.Types, [], json: MedFabric.Store.JSON)

defmodule MedFabric.Store.Postgres do
  @moduledoc "Native PostgreSQL connection and schema setup."

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    {url, opts} = Keyword.pop!(opts, :url)
    uri = URI.new!(url)

    unless uri.scheme in ["postgres", "postgresql"] and is_binary(uri.path) and
             byte_size(uri.path) > 1,
           do: raise(ArgumentError, "Expected a PostgreSQL database URL")

    auth = credentials(uri.userinfo)
    connection = Enum.map(URI.decode_query(uri.query || ""), &connection_option/1)
    location = if connection[:socket_dir], do: [], else: [hostname: uri.host || "localhost"]

    Postgrex.start_link(
      [
        database: URI.decode(String.trim_leading(uri.path, "/")),
        port: uri.port || 5432,
        types: MedFabric.Store.Postgres.Types
      ] ++
        location ++ auth ++ connection ++ opts
    )
  end

  defp credentials(nil), do: []

  defp credentials(info) do
    case String.split(info, ":", parts: 2) do
      [user] -> [username: URI.decode(user)]
      [user, pw] -> [username: URI.decode(user), password: URI.decode(pw)]
    end
  end

  defp connection_option({"host", "/" <> _ = path}), do: {:socket_dir, path}
  defp connection_option({"sslmode", "disable"}), do: {:ssl, false}

  defp connection_option({"sslmode", "verify-full"}),
    do: {:ssl, [verify: :verify_peer, cacerts: :public_key.cacerts_get()]}

  defp connection_option({key, _}),
    do: raise(ArgumentError, "Unsupported PostgreSQL URL option #{key}")

  @tables ~w(deployment_identity encounters browser_sessions encounter_exports device_credentials device_grants acquisitions browser_creations acquisition_sessions stream_attempts acquisition_facts transport_observations measurement_events device_commands acquisition_manifest_staging acquisition_manifests manual_evidence reviews observations outbox_deliveries delivery_attempts)

  def migrate(db, deployment_uuid) do
    app = Application.get_application(__MODULE__) || :mf_store
    path = Application.app_dir(app, "priv/sql/001_schema_v2.sql")

    with true <-
           is_binary(deployment_uuid) and
             Regex.match?(
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
               deployment_uuid
             ),
         {:ok, bytes} <- File.read(path) do
      checksum = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      Postgrex.transaction(db, fn tx ->
        query(tx, "SELECT pg_advisory_xact_lock(73160649)", [])

        tables =
          query(
            tx,
            "SELECT tablename FROM pg_tables WHERE schemaname=current_schema() ORDER BY tablename",
            []
          )
          |> List.flatten()

        migrate_tables!(tx, tables, bytes, deployment_uuid, checksum)

        :ok
      end)
    else
      _ -> {:error, :schema_resource_or_identity_missing}
    end
  end

  defp migrate_tables!(tx, tables, bytes, deployment_uuid, checksum) do
    cond do
      tables == [] ->
        bytes
        |> String.split("-- statement")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.each(&query(tx, &1, []))

        fingerprint = schema_fingerprint(tx)

        query(
          tx,
          "INSERT INTO deployment_identity(singleton,deployment_uuid,revision,migration_sha256,schema_fingerprint) VALUES(true,$1::text::uuid,2,$2,$3)",
          [deployment_uuid, checksum, fingerprint]
        )

      Enum.sort(tables) == Enum.sort(@tables) ->
        verify_deployment!(tx, deployment_uuid, checksum)

      true ->
        Postgrex.rollback(tx, :incompatible_schema)
    end
  end

  defp verify_deployment!(tx, deployment_uuid, checksum) do
    case query(
           tx,
           "SELECT deployment_uuid::text,revision,migration_sha256,schema_fingerprint FROM deployment_identity WHERE singleton",
           []
         ) do
      [[^deployment_uuid, 2, ^checksum, fingerprint]] ->
        unless fingerprint == schema_fingerprint(tx),
          do: Postgrex.rollback(tx, :schema_drift)

      _ ->
        Postgrex.rollback(tx, :incompatible_deployment)
    end
  end

  def identity(db) do
    case query(
           db,
           "SELECT deployment_uuid::text,revision,recovery_state FROM deployment_identity WHERE singleton",
           []
         ) do
      [[uuid, 2, state]] -> {:ok, %{deployment_uuid: uuid, revision: 2, recovery_state: state}}
      _ -> {:error, :incompatible_deployment}
    end
  end

  def backend_id(tx), do: query(tx, "SELECT pg_backend_pid()", []) |> hd() |> hd()

  defp schema_fingerprint(tx) do
    columns =
      query(
        tx,
        "SELECT table_name,column_name,data_type,is_nullable,column_default FROM information_schema.columns WHERE table_schema=current_schema() ORDER BY table_name,ordinal_position",
        []
      )

    constraints =
      query(
        tx,
        "SELECT c.relname,k.conname,pg_get_constraintdef(k.oid) FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=current_schema() ORDER BY c.relname,k.conname",
        []
      )

    triggers =
      query(
        tx,
        "SELECT c.relname,t.tgname,pg_get_triggerdef(t.oid) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=current_schema() AND NOT t.tgisinternal ORDER BY c.relname,t.tgname",
        []
      )

    indexes =
      query(
        tx,
        "SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname=current_schema() ORDER BY tablename,indexname",
        []
      )

    functions =
      query(
        tx,
        "SELECT p.proname,pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=current_schema() AND p.prokind='f' ORDER BY p.proname,p.oid",
        []
      )

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({columns, constraints, triggers, indexes, functions}, [
        :deterministic
      ])
    )
    |> Base.encode16(case: :lower)
  end

  defp query(tx, sql, args), do: Postgrex.query!(tx, sql, args).rows
end
