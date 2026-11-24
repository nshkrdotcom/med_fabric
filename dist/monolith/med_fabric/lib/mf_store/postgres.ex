defmodule MedFabric.Store.Postgres do
  @moduledoc "Atomic recording intake, review and manual export."
  alias MedFabric.Domain.Encounter

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
      [database: URI.decode(String.trim_leading(uri.path, "/")), port: uri.port || 5432] ++
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

  def migrate(db \\ __MODULE__) do
    sql =
      Application.app_dir(
        Application.get_application(__MODULE__),
        "priv/sql/001_clinical_outbox.sql"
      )
      |> File.read!()

    Postgrex.transaction(db, fn conn ->
      Postgrex.query!(conn, "SELECT pg_advisory_xact_lock(73160649)", [])

      sql
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.each(&Postgrex.query!(conn, &1, []))
    end)
  end

  def ready(db, {enc, acq}, session, %{acquisition_id: acq} = capture, source, refs \\ %{}) do
    with {:ok, metadata} <- Encounter.metadata(session, capture, source),
         {:ok, %{rows: [[conflict]]}} <-
           Postgrex.query(
             db,
             """
             INSERT INTO exam_recordings AS r (encounter_id, acquisition_id, metadata) VALUES ($1,$2,$3)
             ON CONFLICT (encounter_id, acquisition_id) DO UPDATE
               SET conflict = r.conflict OR r.metadata <> EXCLUDED.metadata RETURNING conflict
             """,
             [enc, acq, Map.put(metadata, "delivery", refs)]
           ) do
      if conflict, do: {:error, :conflicting_recording}, else: :ok
    end
  end

  def fetch(db, {enc, acq}) do
    case Postgrex.query(
           db,
           """
           SELECT r.metadata, r.conflict, r.accepted_by, r.accepted_at, d.remote_ref, d.last_error
           FROM exam_recordings r LEFT JOIN exam_deliveries d USING (encounter_id, acquisition_id)
           WHERE encounter_id=$1 AND acquisition_id=$2
           """,
           [enc, acq]
         ) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[m, conflict, actor, time, remote, error]]}} ->
        {:ok,
         %{
           metadata: m,
           conflict: conflict,
           accepted_by: actor,
           accepted_at: time,
           remote_ref: remote,
           last_error: error
         }}

      error ->
        error
    end
  end

  def bytes(dir, %{"file_sha256" => digest}) do
    with {:ok, bytes} <- File.read(Path.join(dir, digest <> ".wav")) do
      if Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == digest,
        do: {:ok, bytes},
        else: {:error, :recording_changed}
    end
  end

  def accept(db, {enc, acq}, dir, digest, actor) when is_binary(actor) and byte_size(actor) > 0 do
    Postgrex.transaction(db, &accept_locked(&1, enc, acq, dir, digest, actor))
  end

  defp accept_locked(conn, enc, acq, dir, digest, actor) do
    case Postgrex.query!(
           conn,
           "SELECT metadata, conflict FROM exam_recordings WHERE encounter_id=$1 AND acquisition_id=$2 FOR UPDATE",
           [enc, acq]
         ).rows do
      [[m, conflict]] ->
        with :ok <- Encounter.review(m, digest, conflict), {:ok, _} <- bytes(dir, m) do
          Postgrex.query!(
            conn,
            "UPDATE exam_recordings SET accepted_by=$3, accepted_at=now() WHERE encounter_id=$1 AND acquisition_id=$2 AND accepted_at IS NULL",
            [enc, acq, actor]
          )

          Postgrex.query!(
            conn,
            "INSERT INTO exam_deliveries (encounter_id, acquisition_id) VALUES ($1,$2) ON CONFLICT DO NOTHING",
            [enc, acq]
          )

          :ok
        else
          {:error, reason} -> Postgrex.rollback(conn, reason)
        end

      [] ->
        Postgrex.rollback(conn, :not_found)
    end
  end

  def delivery_result(db, {enc, acq}, result) do
    {remote, error} =
      case result do
        {:ok, %{remote_ref: ref}} ->
          {ref, nil}

        {:error, reason} ->
          {nil, inspect(reason, limit: 3, printable_limit: 80) |> String.slice(0, 160)}
      end

    case Postgrex.query(
           db,
           """
           UPDATE exam_deliveries SET remote_ref=coalesce(remote_ref,$3), attempts=attempts+1,
             last_error=CASE WHEN remote_ref IS NULL THEN $4 ELSE NULL END
           WHERE encounter_id=$1 AND acquisition_id=$2 AND (remote_ref IS NULL OR remote_ref=$3)
           RETURNING remote_ref
           """,
           [enc, acq, remote, error]
         ) do
      {:ok, %{rows: [[nil]]}} -> result
      {:ok, %{rows: [[^remote]]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :delivery_state_changed}
      error -> error
    end
  end
end
