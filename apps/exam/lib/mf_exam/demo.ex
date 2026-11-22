defmodule MedFabric.Exam.Demo do
  @moduledoc """
  Owns live state for the single explicitly enabled synthetic exam.
  PostgreSQL owns committed acceptance and delivery.
  """
  use GenServer

  alias MedCore.Session
  alias MedFabric.Domain.Encounter
  alias MedFabric.Exam
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.Postgres
  alias MedRTC.WavCapture

  @pubsub MedFabric.Exam.PubSub
  @acquisition "circor-1"

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def capture, do: GenServer.call(__MODULE__, :capture)
  def accept(digest, actor), do: GenServer.call(__MODULE__, {:accept, digest, actor})

  def topic(encounter_id), do: "exam:" <> encounter_id
  def preview_topic(encounter_id), do: "preview:" <> encounter_id

  def deliver do
    %{record: record} = snapshot()
    config = Application.fetch_env!(:mf_exam, :lab)

    with %{observation: observation, provenance: provenance, outbox: outbox} <- record,
         opts = [base_url: config.fhir_base_url],
         {:ok, refs} <- FhirClient.seed_exam(config.encounter_id, opts),
         resource =
           FhirClient.build_observation(observation, outbox, provenance, Map.to_list(refs)),
         {:ok, delivered} <- deliver_intent(resource, outbox, opts) do
      GenServer.call(__MODULE__, {:delivered, delivered})
    else
      nil -> {:error, :acceptance_required}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def init(config) do
    :ok = Postgres.migrate()
    session = Exam.start_session(config.encounter_id, "preview-" <> config.encounter_id)

    record =
      case Postgres.fetch_record(Postgres, "obs:#{config.encounter_id}:#{@acquisition}") do
        {:ok, existing} -> existing
        :error -> nil
      end

    {:ok,
     %{
       config: config,
       session: session,
       encounter: Encounter.new(config.encounter_id),
       record: record,
       capture: nil,
       artifact: nil,
       error: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    view = Map.take(state, [:session, :record, :capture, :artifact, :error])
    {:reply, Map.put(view, :encounter_id, state.config.encounter_id), state}
  end

  def handle_call(:capture, _from, %{record: nil, capture: nil, artifact: nil} = state) do
    config = state.config

    {:ok, encounter} =
      Encounter.request_acquisition(state.encounter, @acquisition, state.session.id)

    {session, _effects} =
      Session.step(
        state.session,
        {:acquisition_started,
         %{acquisition_id: @acquisition, stream_id: "auscultation", t_ms: 0}}
      )

    path = Path.join(config.artifact_dir, config.encounter_id <> ".wav")
    topic = preview_topic(config.encounter_id)
    File.mkdir_p!(config.artifact_dir)

    task =
      Task.Supervisor.async_nolink(MedFabric.Exam.CaptureTasks, fn ->
        WavCapture.record(
          Path.join(config.fixture_dir, "2530_AV.wav"),
          Path.join(config.fixture_dir, "2530_AV.opus"),
          path,
          acquisition_id: @acquisition,
          on_preview_frame: fn index, frame ->
            Phoenix.PubSub.broadcast(@pubsub, topic, {:preview_frame, index, frame})
          end
        )
      end)

    next = %{state | capture: task.ref, encounter: encounter, session: session, error: nil}
    announce(next)
    {:reply, :ok, next}
  end

  def handle_call(:capture, _from, state), do: {:reply, {:error, :capture_exists}, state}

  def handle_call({:accept, digest, actor}, _from, state) do
    case accept_capture(state, digest, actor) do
      {:ok, encounter, record} ->
        next = %{state | encounter: encounter, record: record}
        announce(next)
        {:reply, :ok, next}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:delivered, outbox}, _from, state) do
    next = put_in(state.record.outbox, outbox)
    announce(next)
    {:reply, :ok, next}
  end

  @impl true
  def handle_info({ref, {:ok, artifact}}, %{capture: ref} = state) do
    Process.demonitor(ref, [:flush])
    {_start, end_ms} = artifact.interval_ms

    completion = %{
      acquisition_id: @acquisition,
      artifact_sha256: artifact.artifact_sha256,
      interval_ms: artifact.interval_ms,
      continuity: artifact.continuity,
      delivery_id: @acquisition,
      t_ms: end_ms
    }

    {session, effects} = Session.step(state.session, {:capture_completed, completion})
    encounter = Exam.ingest_effects(state.encounter, effects)
    next = %{state | capture: nil, artifact: artifact, encounter: encounter, session: session}
    announce(next)
    {:noreply, next}
  end

  def handle_info({ref, {:error, reason}}, %{capture: ref} = state) do
    Process.demonitor(ref, [:flush])
    capture_failed(state, reason)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{capture: ref} = state) do
    capture_failed(state, reason)
  end

  defp capture_failed(state, reason) do
    next = %{
      state
      | capture: nil,
        error: reason,
        session: Exam.start_session(state.config.encounter_id, state.session.id)
    }

    announce(next)
    {:noreply, next}
  end

  defp accept_capture(
         %{record: %{observation: %{artifact_sha256: digest}} = record} = state,
         digest,
         _actor
       ),
       do: {:ok, state.encounter, record}

  defp accept_capture(%{record: %{}}, _digest, _actor), do: {:error, :digest_mismatch}

  defp accept_capture(%{artifact: artifact} = state, digest, actor) when is_map(artifact) do
    provenance =
      artifact
      |> Map.take([:artifact_path, :sample_rate_hz, :sample_count, :duration_ms])
      |> Map.merge(%{source_kind: :physionet_circor, source_ref: "2530_AV.wav"})

    with {:ok, encounter, acceptance} <-
           Encounter.accept_acquisition(state.encounter, @acquisition, digest, actor),
         {:ok, _status, record} <- Postgres.commit_acceptance(Postgres, acceptance, provenance) do
      {:ok, encounter, record}
    end
  end

  defp accept_capture(_state, _digest, _actor), do: {:error, :recording_not_ready}

  defp deliver_intent(_resource, %{status: :delivered} = outbox, _opts), do: {:ok, outbox}

  defp deliver_intent(resource, outbox, opts) do
    case FhirClient.deliver(resource, opts) do
      {:ok, %{remote_ref: remote_ref}} ->
        Postgres.mark_delivered(Postgres, outbox.intent_id, remote_ref)

      {:error, reason} ->
        Postgres.mark_delivery_failed(
          Postgres,
          outbox.intent_id,
          reason,
          System.system_time(:millisecond)
        )

        {:error, reason}
    end
  end

  defp announce(state) do
    Phoenix.PubSub.broadcast(@pubsub, topic(state.config.encounter_id), :exam_changed)
  end
end
