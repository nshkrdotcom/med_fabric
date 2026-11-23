defmodule MedFabric.Exam.Recordings do
  @moduledoc "Coordinates local capture ownership and durable recording attempts."

  alias MedFabric.Domain.Evidence
  alias MedFabric.Exam
  alias MedFabric.Exam.Artifact
  alias MedFabric.Store.Records

  def active(encounter) do
    case :global.whereis_name({__MODULE__, encounter}) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      :undefined -> nil
    end
  end

  def admit(encounter, actor, context \\ Exam.context()) do
    locked(encounter, fn ->
      with true <- Exam.member?(encounter, actor, :patient, context.db),
           nil <- active(encounter),
           :ok <- reconcile(encounter, context) do
        start_capture(encounter, actor, context)
      else
        {:error, _} = error -> error
        _ -> {:error, :capture_unavailable}
      end
    end)
  end

  defp start_capture(encounter, actor, context) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    root = context.artifact_dir

    with :ok <- Artifact.create_directory(root, id),
         :ok <- Records.reserve(context.db, encounter, id, actor),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             context.captures,
             {MedEx.Capture, owner: self(), acquisition_id: id, artifact_dir: Path.join(root, id)}
           ) do
      # Name the writer itself. If the socket dies during finish, the name stays
      # occupied until the writer has finished installing (or aborting) the file.
      :yes = :global.register_name({__MODULE__, encounter}, pid)

      Phoenix.PubSub.broadcast(
        context.pubsub,
        "preview:" <> encounter,
        {:capture_started, pid}
      )

      {:ok, id, pid}
    end
  end

  def finish(encounter, id, actor, pid, context \\ Exam.context()) do
    locked(encounter, fn ->
      with ^pid <- active(encounter),
           true <- Exam.member?(encounter, actor, :patient, context.db),
           {:ok, %{id: ^id, producer: ^actor} = row} <- Records.pending(context.db, encounter),
           {:ok, artifact} <- MedEx.Capture.finish(pid) do
        complete(encounter, row, artifact, context)
      else
        {:error, _} = error -> error
        _ -> {:error, :capture_unavailable}
      end
    end)
  end

  def recover(context \\ Exam.context()) do
    with {:ok, encounters} <- Records.pending_encounters(context.db, context.encounter_ids) do
      Enum.reduce_while(encounters, :ok, fn encounter, :ok ->
        recover_encounter(encounter, context)
      end)
    end
  end

  defp recover_encounter(encounter, context) do
    case locked(encounter, fn -> reconcile(encounter, context) end) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  def status(encounter, id, context \\ Exam.context()) do
    case Records.recording_status(context.db, encounter, id) do
      {:ok, "recording"} ->
        refresh_status(encounter, id, context)

      result ->
        result
    end
  end

  defp refresh_status(encounter, id, context) do
    locked(encounter, fn ->
      with :ok <- reconcile(encounter, context) do
        Records.recording_status(context.db, encounter, id)
      end
    end)
  end

  defp locked(encounter, fun) do
    :global.trans({{__MODULE__, encounter}, self()}, fun, [node()])
  end

  defp reconcile(encounter, context) do
    with nil <- active(encounter),
         {:ok, %{} = row} <- Records.pending(context.db, encounter),
         :ok <- Artifact.remove_partials(context.artifact_dir, row.id) do
      recover_attempt(encounter, row, context)
    else
      pid when is_pid(pid) -> :ok
      {:ok, nil} -> :ok
      error -> error
    end
  end

  defp recover_attempt(encounter, row, context) do
    with {:ok, file} <- Artifact.finalized(context.artifact_dir, row.id),
         artifact = recovered_artifact(file, row.id),
         :ok <- complete(encounter, row, artifact, context) do
      :ok
    else
      {:error, reason} when reason in [:unfinished, :invalid_recording] ->
        Records.interrupt(context.db, encounter, row.id)

      error ->
        error
    end
  end

  # Only the capture writer installs a final WAV in this reserved directory, after
  # validating the stream from sample zero. Recovery relies on that installation
  # contract for continuity, and on the file for the sample count.
  defp recovered_artifact(file, id) do
    Map.merge(file, %{
      acquisition_id: id,
      kind: :audio_pcm16_wav,
      first_sample: 0,
      end_sample: file.sample_count,
      continuity: :observed_continuous
    })
  end

  defp complete(encounter, %{id: id} = row, %{acquisition_id: id} = artifact, context) do
    with {:ok, evidence} <-
           Evidence.recording(artifact, row.producer, row.source, row.first_received_at),
         :ok <- Records.complete(context.db, encounter, id, evidence) do
      Exam.announce(encounter, context)
    end
  end
end
