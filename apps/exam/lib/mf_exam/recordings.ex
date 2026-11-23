defmodule MedFabric.Exam.Recordings do
  @moduledoc "Coordinates local capture ownership and durable recording attempts."

  alias MedFabric.Domain.Evidence
  alias MedFabric.Exam
  alias MedFabric.Exam.Artifact
  alias MedFabric.Store.{Postgres, Records}

  def active(encounter) do
    case :global.whereis_name({__MODULE__, encounter}) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      :undefined -> nil
    end
  end

  def admit(encounter, actor) do
    locked(encounter, fn ->
      with true <- Records.member?(Postgres, encounter, actor, :patient),
           nil <- active(encounter),
           :ok <- reconcile(encounter) do
        id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        root = Exam.lab().artifact_dir

        with :ok <- Artifact.create_directory(root, id),
             :ok <- Records.reserve(Postgres, encounter, id, actor),
             {:ok, pid} <-
               DynamicSupervisor.start_child(
                 Exam.Captures,
                 {MedEx.Capture,
                  owner: self(), acquisition_id: id, artifact_dir: Path.join(root, id)}
               ) do
          # Name the writer itself. If the socket dies during finish, the name stays
          # occupied until the writer has finished installing (or aborting) the file.
          :yes = :global.register_name({__MODULE__, encounter}, pid)
          Phoenix.PubSub.broadcast(Exam.PubSub, "preview:" <> encounter, {:capture_started, pid})
          {:ok, id, pid}
        end
      else
        {:error, _} = error -> error
        _ -> {:error, :capture_unavailable}
      end
    end)
  end

  def finish(encounter, id, actor, pid) do
    locked(encounter, fn ->
      with ^pid <- active(encounter),
           true <- Records.member?(Postgres, encounter, actor, :patient),
           {:ok, %{id: ^id, producer: ^actor} = row} <- Records.pending(Postgres, encounter),
           {:ok, artifact} <- MedEx.Capture.finish(pid) do
        complete(encounter, row, artifact)
      else
        {:error, _} = error -> error
        _ -> {:error, :capture_unavailable}
      end
    end)
  end

  def recover do
    with {:ok, encounters} <-
           Records.pending_encounters(Postgres, Map.keys(Exam.lab().encounters)) do
      Enum.reduce_while(encounters, :ok, fn encounter, :ok ->
        case locked(encounter, fn -> reconcile(encounter) end) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  def status(encounter, id) do
    case Records.recording_status(Postgres, encounter, id) do
      {:ok, "recording"} ->
        locked(encounter, fn ->
          with :ok <- reconcile(encounter), do: Records.recording_status(Postgres, encounter, id)
        end)

      result ->
        result
    end
  end

  defp locked(encounter, fun) do
    :global.trans({{__MODULE__, encounter}, self()}, fun, [node()])
  end

  defp reconcile(encounter) do
    with nil <- active(encounter),
         {:ok, %{} = row} <- Records.pending(Postgres, encounter) do
      root = Exam.lab().artifact_dir

      with :ok <- Artifact.remove_partials(root, row.id) do
        case Artifact.finalized(root, row.id) do
          {:ok, artifact} ->
            case complete(encounter, row, artifact) do
              {:error, :invalid_recording} -> Records.interrupt(Postgres, encounter, row.id)
              result -> result
            end

          {:error, reason} when reason in [:unfinished, :invalid_recording] ->
            Records.interrupt(Postgres, encounter, row.id)

          error ->
            error
        end
      end
    else
      pid when is_pid(pid) -> :ok
      {:ok, nil} -> :ok
      error -> error
    end
  end

  defp complete(encounter, %{id: id} = row, %{acquisition_id: id} = artifact) do
    with {:ok, evidence} <-
           Evidence.recording(artifact, row.producer, row.source, row.first_received_at),
         :ok <- Records.complete(Postgres, encounter, id, evidence) do
      Exam.announce(encounter)
    end
  end
end
