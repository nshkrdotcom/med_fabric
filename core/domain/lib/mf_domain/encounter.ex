defmodule MedFabric.Domain.Encounter do
  @moduledoc """
  Pure clinical `Encounter` aggregate and consumer acceptance state machine.

  Owns durable clinical encounter identity (`encounter_ref`), requested
  acquisitions, review candidates, digest-conflict blocking, and explicit
  clinician acceptance producing one observation and one export intent.
  Live transport preview status remains strictly transient and never alters
  recording integrity or blocks valid recording review.
  """

  @type encounter_id :: String.t()
  @type acquisition_id :: String.t()
  @type continuity_state :: :observed_continuous | :observed_gap | :unknown

  @type review_candidate :: %{
          required(:acquisition_id) => acquisition_id(),
          required(:session_id) => String.t(),
          required(:artifact_sha256) => String.t(),
          required(:interval_ms) => {non_neg_integer(), non_neg_integer()},
          required(:continuity) => continuity_state(),
          required(:status) => :ready_for_review | :conflict | :accepted,
          optional(:conflicting_sha256) => String.t()
        }

  @type acceptance_result :: %{
          required(:observation) => map(),
          required(:export_intent) => map()
        }

  @type t :: %__MODULE__{
          id: encounter_id(),
          status: :open | :closed,
          requested_acquisitions: %{acquisition_id() => map()},
          review_candidates: %{acquisition_id() => review_candidate()},
          accepted_observations: %{acquisition_id() => map()},
          transient_preview_state: map()
        }

  @enforce_keys [:id]
  defstruct [
    :id,
    status: :open,
    requested_acquisitions: %{},
    review_candidates: %{},
    accepted_observations: %{},
    transient_preview_state: %{}
  ]

  @spec new(encounter_id()) :: t()
  def new(id) when is_binary(id), do: %__MODULE__{id: id}

  @spec close(t()) :: t()
  def close(%__MODULE__{} = encounter), do: %{encounter | status: :closed}

  @spec request_acquisition(t(), acquisition_id(), String.t()) ::
          {:ok, t()} | {:error, :encounter_closed | :acquisition_already_bound}
  def request_acquisition(%__MODULE__{status: :closed}, _acq_id, _session_id),
    do: {:error, :encounter_closed}

  def request_acquisition(%__MODULE__{} = encounter, acq_id, session_id)
      when is_binary(acq_id) and is_binary(session_id) do
    case Map.get(encounter.requested_acquisitions, acq_id) do
      nil ->
        requests = Map.put(encounter.requested_acquisitions, acq_id, %{session_id: session_id})
        {:ok, %{encounter | requested_acquisitions: requests}}

      %{session_id: ^session_id} ->
        {:ok, encounter}

      _ ->
        {:error, :acquisition_already_bound}
    end
  end

  @doc """
  Applies a producer fact emitted by `:med_ex` (`MedCore.Session`) to the encounter.
  """
  @spec apply_fact(t(), {atom(), map()}) :: t()
  def apply_fact(%__MODULE__{} = encounter, {:peer_connection_changed, payload}) do
    preview =
      Map.put(encounter.transient_preview_state, payload.connection_id, %{
        peer_id: payload.peer_id,
        state: payload.state,
        t_ms: payload.t_ms
      })

    %{encounter | transient_preview_state: preview}
  end

  def apply_fact(
        %__MODULE__{} = encounter,
        {:integrity_reported, %{subject: {:preview_stream, stream_id}} = report}
      ) do
    preview = Map.put(encounter.transient_preview_state, {:preview_stream, stream_id}, report)
    %{encounter | transient_preview_state: preview}
  end

  def apply_fact(%__MODULE__{} = encounter, {:integrity_reported, _recording_report}) do
    encounter
  end

  def apply_fact(
        %__MODULE__{id: encounter_id, status: :open} = encounter,
        {:capture_completed,
         %{
           encounter_ref: encounter_id,
           acquisition_id: acq_id,
           session_id: session_id,
           artifact_sha256: sha256,
           interval_ms: interval_ms,
           continuity: continuity
         }}
      ) do
    case {Map.get(encounter.requested_acquisitions, acq_id),
          Map.get(encounter.review_candidates, acq_id)} do
      {%{session_id: ^session_id} = request, nil} ->
        candidate = %{
          acquisition_id: acq_id,
          session_id: session_id,
          artifact_sha256: sha256,
          interval_ms: interval_ms,
          continuity: continuity,
          status: :ready_for_review
        }

        candidate =
          case request do
            %{conflicting_sha256: digest} ->
              Map.merge(candidate, %{status: :conflict, conflicting_sha256: digest})

            _ ->
              candidate
          end

        put_candidate(encounter, acq_id, candidate)

      {%{session_id: ^session_id},
       %{status: :ready_for_review, artifact_sha256: digest} = candidate}
      when digest != sha256 ->
        put_candidate(
          encounter,
          acq_id,
          Map.merge(candidate, %{status: :conflict, conflicting_sha256: sha256})
        )

      _ ->
        encounter
    end
  end

  def apply_fact(
        %__MODULE__{id: encounter_id, status: :open} = encounter,
        {:capture_conflict,
         %{
           encounter_ref: encounter_id,
           session_id: session_id,
           acquisition_id: acq_id,
           incoming_sha256: digest
         }}
      ) do
    case {Map.get(encounter.requested_acquisitions, acq_id),
          Map.get(encounter.review_candidates, acq_id)} do
      {%{session_id: ^session_id}, %{status: :ready_for_review} = candidate} ->
        put_candidate(
          encounter,
          acq_id,
          Map.merge(candidate, %{status: :conflict, conflicting_sha256: digest})
        )

      {%{session_id: ^session_id} = request, nil} ->
        requests =
          Map.put(
            encounter.requested_acquisitions,
            acq_id,
            Map.put_new(request, :conflicting_sha256, digest)
          )

        %{encounter | requested_acquisitions: requests}

      _ ->
        encounter
    end
  end

  def apply_fact(%__MODULE__{} = encounter, _event), do: encounter

  defp put_candidate(encounter, acq_id, candidate) do
    %{encounter | review_candidates: Map.put(encounter.review_candidates, acq_id, candidate)}
  end

  @doc """
  Explicit clinician acceptance of a reviewable acquisition.

  Returns `{:ok, next_encounter, %{observation: ..., export_intent: ...}}` on
  first acceptance or idempotent retry with the matching digest. Blocks when
  the acquisition is missing, in `:conflict`, or the digest does not match.
  """
  @spec accept_acquisition(t(), acquisition_id(), String.t(), String.t()) ::
          {:ok, t(), acceptance_result()}
          | {:error,
             :not_found | :conflict_blocks_acceptance | :digest_mismatch | :encounter_closed}
  def accept_acquisition(%__MODULE__{} = encounter, acq_id, artifact_sha256, clinician_id)
      when is_binary(acq_id) and is_binary(artifact_sha256) and is_binary(clinician_id) do
    case Map.get(encounter.review_candidates, acq_id) do
      nil ->
        {:error, :not_found}

      %{status: :conflict} ->
        {:error, :conflict_blocks_acceptance}

      %{artifact_sha256: expected} when expected != artifact_sha256 ->
        {:error, :digest_mismatch}

      %{status: :accepted} ->
        obs = Map.fetch!(encounter.accepted_observations, acq_id)
        {:ok, encounter, %{observation: obs, export_intent: export_intent_for(obs)}}

      %{status: :ready_for_review} when encounter.status == :closed ->
        {:error, :encounter_closed}

      %{status: :ready_for_review} = candidate ->
        observation = %{
          observation_id: "obs:#{encounter.id}:#{acq_id}",
          encounter_id: encounter.id,
          acquisition_id: acq_id,
          session_id: candidate.session_id,
          artifact_sha256: candidate.artifact_sha256,
          interval_ms: candidate.interval_ms,
          continuity: candidate.continuity,
          accepted_by: clinician_id
        }

        updated_candidate = %{candidate | status: :accepted}

        next = %{
          encounter
          | review_candidates: Map.put(encounter.review_candidates, acq_id, updated_candidate),
            accepted_observations: Map.put(encounter.accepted_observations, acq_id, observation)
        }

        {:ok, next, %{observation: observation, export_intent: export_intent_for(observation)}}
    end
  end

  defp export_intent_for(observation) do
    %{
      intent_id: "export:#{observation.observation_id}",
      target: :fhir_r4,
      observation_id: observation.observation_id,
      artifact_sha256: observation.artifact_sha256
    }
  end
end
