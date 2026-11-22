defmodule MedFabric.Store.OutboxStore do
  @moduledoc """
  Atomic clinical acceptance persistence and transactional FHIR export outbox.

  Commits an accepted observation, its recording artifact provenance, and its
  FHIR export outbox intent in one serialized transaction keyed by
  `observation_id` / `intent_id`. Retrying after either a pre-commit crash or
  a post-commit lost-reply crash converges on exactly one observation and one
  export intent.

  Runs completely offline in-memory via a supervised `GenServer` for ordinary
  Mix/Blitz/Weld test suites while defining the exact transactional contract
  for the optional PostgreSQL 17 schema in `priv/sql/001_clinical_outbox.sql`.
  """

  use GenServer

  alias MedFabric.Domain.Encounter

  @type outbox_status :: :pending | :retry_scheduled | :delivered

  @type outbox_entry :: %{
          required(:intent_id) => String.t(),
          required(:observation_id) => String.t(),
          required(:target) => atom(),
          required(:external_id) => String.t(),
          required(:artifact_sha256) => String.t(),
          required(:status) => outbox_status(),
          required(:attempts) => non_neg_integer(),
          optional(:last_error) => term(),
          optional(:next_retry_at_ms) => non_neg_integer(),
          optional(:remote_ref) => String.t()
        }

  @type committed_record :: %{
          required(:observation) => map(),
          required(:provenance) => map(),
          required(:outbox) => outbox_entry()
        }

  @doc """
  Starts an `OutboxStore` process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
  end

  @doc """
  Atomically commits an accepted observation, artifact provenance, and export
  outbox intent.

  Idempotent on `observation.observation_id` when `artifact_sha256` matches;
  fails closed with `{:error, :conflicting_observation_digest}` if the same
  observation ID is retried with a different digest.

  Optional hooks for deterministic crash-recovery testing:
  - `:before_commit` (`(-> :ok | {:error, term()})`) runs before state changes.
  - `:after_commit` (`(committed_record() -> term())`) runs in the caller
    *after* the atomic commit succeeds (allowing tests to simulate a lost reply
    or process crash after DB commit).
  """
  @spec commit_acceptance(GenServer.server(), Encounter.acceptance_result(), map(), keyword()) ::
          {:ok, :committed | :already_committed, committed_record()}
          | {:error, term()}
  def commit_acceptance(
        server,
        %{observation: observation, export_intent: export_intent},
        provenance,
        opts \\ []
      )
      when is_map(observation) and is_map(export_intent) and is_map(provenance) do
    before_commit = Keyword.get(opts, :before_commit)
    after_commit = Keyword.get(opts, :after_commit)

    result =
      GenServer.call(
        server,
        {:commit_acceptance, observation, export_intent, provenance, before_commit}
      )

    case result do
      {:ok, _status, record} = ok ->
        if is_function(after_commit, 1), do: after_commit.(record)
        ok

      error ->
        error
    end
  end

  @doc """
  Marks an outbox intent as failed and schedules a retry.
  """
  @spec mark_delivery_failed(GenServer.server(), String.t(), term(), non_neg_integer()) ::
          {:ok, outbox_entry()} | {:error, :not_found}
  def mark_delivery_failed(server, intent_id, reason, next_retry_at_ms)
      when is_binary(intent_id) and is_integer(next_retry_at_ms) and next_retry_at_ms >= 0 do
    GenServer.call(server, {:mark_delivery_failed, intent_id, reason, next_retry_at_ms})
  end

  @doc """
  Marks an outbox intent as delivered with the remote server's resource ref.
  """
  @spec mark_delivered(GenServer.server(), String.t(), String.t()) ::
          {:ok, outbox_entry()} | {:error, :not_found}
  def mark_delivered(server, intent_id, remote_ref)
      when is_binary(intent_id) and is_binary(remote_ref) do
    GenServer.call(server, {:mark_delivered, intent_id, remote_ref})
  end

  @doc """
  Returns all committed observations.
  """
  @spec list_observations(GenServer.server()) :: [map()]
  def list_observations(server), do: GenServer.call(server, :list_observations)

  @doc """
  Returns all outbox entries.
  """
  @spec list_outbox(GenServer.server()) :: [outbox_entry()]
  def list_outbox(server), do: GenServer.call(server, :list_outbox)

  @doc """
  Fetches a single committed record by `observation_id`.
  """
  @spec fetch_record(GenServer.server(), String.t()) :: {:ok, committed_record()} | :error
  def fetch_record(server, observation_id) when is_binary(observation_id) do
    GenServer.call(server, {:fetch_record, observation_id})
  end

  @doc """
  Fetches a single outbox entry by `intent_id`.
  """
  @spec fetch_outbox(GenServer.server(), String.t()) :: {:ok, outbox_entry()} | :error
  def fetch_outbox(server, intent_id) when is_binary(intent_id) do
    GenServer.call(server, {:fetch_outbox, intent_id})
  end

  @impl true
  def init(:ok) do
    {:ok, %{observations: %{}, provenance: %{}, outbox: %{}}}
  end

  @impl true
  def handle_call(
        {:commit_acceptance, observation, export_intent, provenance, before_commit},
        _from,
        state
      ) do
    obs_id = Map.fetch!(observation, :observation_id)
    intent_id = Map.fetch!(export_intent, :intent_id)

    case Map.get(state.observations, obs_id) do
      %{artifact_sha256: existing_sha} = existing_obs ->
        if existing_sha == observation.artifact_sha256 do
          record = %{
            observation: existing_obs,
            provenance: Map.fetch!(state.provenance, obs_id),
            outbox: Map.fetch!(state.outbox, intent_id)
          }

          {:reply, {:ok, :already_committed, record}, state}
        else
          {:reply, {:error, :conflicting_observation_digest}, state}
        end

      nil ->
        case run_before_commit(before_commit) do
          :ok ->
            outbox_entry = %{
              intent_id: intent_id,
              observation_id: obs_id,
              target: Map.fetch!(export_intent, :target),
              external_id: "urn:med_fabric:observation:#{obs_id}",
              artifact_sha256: observation.artifact_sha256,
              status: :pending,
              attempts: 0
            }

            next_state = %{
              observations: Map.put(state.observations, obs_id, observation),
              provenance: Map.put(state.provenance, obs_id, provenance),
              outbox: Map.put(state.outbox, intent_id, outbox_entry)
            }

            record = %{
              observation: observation,
              provenance: provenance,
              outbox: outbox_entry
            }

            {:reply, {:ok, :committed, record}, next_state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:mark_delivery_failed, intent_id, reason, next_retry_at_ms}, _from, state) do
    case Map.get(state.outbox, intent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated =
          entry
          |> Map.put(:status, :retry_scheduled)
          |> Map.put(:attempts, entry.attempts + 1)
          |> Map.put(:last_error, reason)
          |> Map.put(:next_retry_at_ms, next_retry_at_ms)

        {:reply, {:ok, updated}, %{state | outbox: Map.put(state.outbox, intent_id, updated)}}
    end
  end

  def handle_call({:mark_delivered, intent_id, remote_ref}, _from, state) do
    case Map.get(state.outbox, intent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated =
          entry
          |> Map.put(:status, :delivered)
          |> Map.put(:attempts, entry.attempts + 1)
          |> Map.put(:remote_ref, remote_ref)
          |> Map.delete(:last_error)

        {:reply, {:ok, updated}, %{state | outbox: Map.put(state.outbox, intent_id, updated)}}
    end
  end

  def handle_call(:list_observations, _from, state) do
    {:reply, Map.values(state.observations), state}
  end

  def handle_call(:list_outbox, _from, state) do
    {:reply, Map.values(state.outbox), state}
  end

  def handle_call({:fetch_record, obs_id}, _from, state) do
    case Map.get(state.observations, obs_id) do
      nil ->
        {:reply, :error, state}

      obs ->
        intent_id = "export:#{obs_id}"

        record = %{
          observation: obs,
          provenance: Map.fetch!(state.provenance, obs_id),
          outbox: Map.fetch!(state.outbox, intent_id)
        }

        {:reply, {:ok, record}, state}
    end
  end

  def handle_call({:fetch_outbox, intent_id}, _from, state) do
    {:reply, Map.fetch(state.outbox, intent_id), state}
  end

  defp run_before_commit(nil), do: :ok
  defp run_before_commit(fun) when is_function(fun, 0), do: fun.()
end
