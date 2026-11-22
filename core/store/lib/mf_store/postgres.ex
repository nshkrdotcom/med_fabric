defmodule MedFabric.Store.Postgres do
  @moduledoc """
  PostgreSQL authority for observations, artifact provenance and FHIR delivery status.

  Repeated acceptance with the same immutable capture identity returns the original
  record, including the recorded actor and delivery status.
  """

  @record_query """
  SELECT row_to_json(o), p.metadata, row_to_json(f)
    FROM accepted_observations o
    JOIN artifact_provenance p USING (observation_id)
    JOIN fhir_export_outbox f USING (observation_id)
   WHERE o.observation_id = $1
  """
  @observation_query """
  INSERT INTO accepted_observations
    (observation_id, encounter_id, acquisition_id, session_id, artifact_sha256,
     interval_start_ms, interval_end_ms, continuity, accepted_by)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
  ON CONFLICT DO NOTHING
  """

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {url, opts} = Keyword.pop!(opts, :url)

    %URI{scheme: scheme, host: host, port: port, userinfo: userinfo, path: "/" <> database} =
      URI.parse(url)

    true = scheme in ["postgres", "postgresql"] and is_binary(host) and is_binary(userinfo)
    [username | password] = String.split(userinfo, ":", parts: 2)

    defaults = [
      hostname: host,
      port: port || 5432,
      database: URI.decode(database),
      username: URI.decode(username)
    ]

    defaults =
      case password do
        [value] -> Keyword.put(defaults, :password, URI.decode(value))
        [] -> defaults
      end

    Postgrex.start_link(Keyword.merge(defaults, opts))
  end

  @spec migrate(GenServer.server()) :: :ok | {:error, term()}
  def migrate(server \\ __MODULE__) do
    statements =
      (Application.get_application(__MODULE__) || :mf_store)
      |> Application.app_dir("priv/sql/001_clinical_outbox.sql")
      |> File.read!()
      |> String.split(";", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Postgrex.transaction(server, fn conn ->
           Postgrex.query!(conn, "SELECT pg_advisory_xact_lock(73160649)", [])
           Enum.each(statements, &Postgrex.query!(conn, &1, []))
         end) do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
  end

  @spec commit_acceptance(GenServer.server(), map(), map()) ::
          {:ok, :committed | :already_committed, map()} | {:error, term()}
  def commit_acceptance(server, %{observation: observation, export_intent: intent}, provenance) do
    with :ok <- validate_intent(observation, intent),
         {:ok, {status, record}} <-
           Postgrex.transaction(server, &commit(&1, observation, intent, provenance)) do
      {:ok, status, record}
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
  end

  @spec fetch_record(GenServer.server(), String.t()) :: {:ok, map()} | :error | {:error, term()}
  def fetch_record(server, observation_id) do
    case Postgrex.query(server, @record_query, [observation_id]) do
      {:ok, %{rows: [[observation, provenance, outbox]]}} ->
        {:ok,
         %{
           observation: observation(observation),
           provenance: provenance(provenance),
           outbox: outbox(outbox)
         }}

      {:ok, %{rows: []}} ->
        :error

      {:error, _} = error ->
        error
    end
  end

  @spec fetch_outbox(GenServer.server(), String.t()) :: {:ok, map()} | :error | {:error, term()}
  def fetch_outbox(server, intent_id) do
    outbox_query(server, "SELECT row_to_json(f) FROM fhir_export_outbox f WHERE intent_id = $1", [
      intent_id
    ])
  end

  @spec mark_delivery_failed(GenServer.server(), String.t(), term(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def mark_delivery_failed(server, intent_id, reason, next_retry_at_ms) do
    statement = """
    UPDATE fhir_export_outbox SET status = 'retry_scheduled', attempts = attempts + 1,
      last_error = $2, next_retry_at_ms = $3
    WHERE intent_id = $1 AND status <> 'delivered'
    RETURNING row_to_json(fhir_export_outbox)
    """

    update_outbox(server, statement, [intent_id, inspect(reason), next_retry_at_ms])
  end

  @spec mark_delivered(GenServer.server(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def mark_delivered(server, intent_id, remote_ref) do
    statement = """
    UPDATE fhir_export_outbox SET status = 'delivered', attempts = attempts + 1,
      remote_ref = $2, last_error = NULL, next_retry_at_ms = NULL
    WHERE intent_id = $1 AND status <> 'delivered'
    RETURNING row_to_json(fhir_export_outbox)
    """

    case update_outbox(server, statement, [intent_id, remote_ref]) do
      {:ok, %{remote_ref: ^remote_ref}} = result -> result
      {:ok, _} -> {:error, :conflicting_remote_reference}
      {:error, _} = error -> error
    end
  end

  defp update_outbox(server, statement, [intent_id | _] = params) do
    case outbox_query(server, statement, params) do
      :error ->
        case fetch_outbox(server, intent_id) do
          :error -> {:error, :not_found}
          result -> result
        end

      result ->
        result
    end
  end

  defp outbox_query(server, statement, params) do
    case Postgrex.query(server, statement, params) do
      {:ok, %{rows: [[row]]}} -> {:ok, outbox(row)}
      {:ok, %{rows: []}} -> :error
      {:error, _} = error -> error
    end
  end

  defp validate_intent(observation, intent) do
    expected = "export:#{observation.observation_id}"

    case intent do
      %{intent_id: ^expected, target: :fhir_r4, observation_id: id, artifact_sha256: digest}
      when id == observation.observation_id and digest == observation.artifact_sha256 ->
        :ok

      _ ->
        {:error, :invalid_export_intent}
    end
  end

  defp commit(conn, observation, intent, provenance) do
    {start_ms, end_ms} = observation.interval_ms
    observation_id = observation.observation_id

    params = [
      observation_id,
      observation.encounter_id,
      observation.acquisition_id,
      observation.session_id,
      observation.artifact_sha256,
      start_ms,
      end_ms,
      Atom.to_string(observation.continuity),
      observation.accepted_by
    ]

    %{num_rows: inserted} = Postgrex.query!(conn, @observation_query, params)

    status =
      case inserted do
        1 ->
          insert_related(conn, observation_id, intent.intent_id, provenance)
          :committed

        0 ->
          :already_committed
      end

    case fetch_record(conn, observation_id) do
      {:ok, %{observation: stored} = record} ->
        if same_capture?(stored, observation),
          do: {status, record},
          else: Postgrex.rollback(conn, :conflicting_observation)

      :error ->
        Postgrex.rollback(conn, :conflicting_observation)

      {:error, reason} ->
        Postgrex.rollback(conn, reason)
    end
  end

  defp insert_related(conn, observation_id, intent_id, provenance) do
    Postgrex.query!(
      conn,
      "INSERT INTO artifact_provenance (observation_id, metadata) VALUES ($1, $2)",
      [observation_id, provenance]
    )

    Postgrex.query!(
      conn,
      """
      INSERT INTO fhir_export_outbox (intent_id, observation_id, external_id, status)
      VALUES ($1, $2, $3, 'pending')
      """,
      [intent_id, observation_id, "urn:med_fabric:observation:#{observation_id}"]
    )
  end

  defp same_capture?(stored, proposed) do
    keys = [
      :encounter_id,
      :acquisition_id,
      :session_id,
      :artifact_sha256,
      :interval_ms,
      :continuity
    ]

    Map.take(stored, keys) == Map.take(proposed, keys)
  end

  defp observation(row) do
    %{
      observation_id: row["observation_id"],
      encounter_id: row["encounter_id"],
      acquisition_id: row["acquisition_id"],
      session_id: row["session_id"],
      artifact_sha256: row["artifact_sha256"],
      interval_ms: {row["interval_start_ms"], row["interval_end_ms"]},
      continuity: continuity(row["continuity"]),
      accepted_by: row["accepted_by"]
    }
  end

  defp continuity("observed_continuous"), do: :observed_continuous
  defp continuity("observed_gap"), do: :observed_gap
  defp continuity("unknown"), do: :unknown

  defp provenance(row) do
    keys = [
      :source_kind,
      :source_ref,
      :artifact_path,
      :sample_rate_hz,
      :sample_count,
      :patient_ref,
      :encounter_ref
    ]

    for key <- keys, {:ok, value} <- [Map.fetch(row, Atom.to_string(key))], into: %{} do
      {key, value}
    end
  end

  defp outbox(row) do
    status =
      case row["status"] do
        "pending" -> :pending
        "retry_scheduled" -> :retry_scheduled
        "delivered" -> :delivered
      end

    %{
      intent_id: row["intent_id"],
      observation_id: row["observation_id"],
      target: :fhir_r4,
      external_id: row["external_id"],
      status: status,
      attempts: row["attempts"],
      last_error: row["last_error"],
      next_retry_at_ms: row["next_retry_at_ms"],
      remote_ref: row["remote_ref"]
    }
  end
end
