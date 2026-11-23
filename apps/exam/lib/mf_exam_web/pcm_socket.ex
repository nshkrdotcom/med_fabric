defmodule MedFabric.ExamWeb.PCMSocket do
  @moduledoc false
  @behaviour WebSock

  alias MedFabric.Domain.Evidence
  alias MedFabric.Exam
  alias MedFabric.ExamWeb.Endpoint
  alias MedFabric.Store.{Postgres, Records}

  def upgrade(conn, _opts) do
    import Plug.Conn
    expected_origin = Endpoint.url() |> URI.parse()

    origin_ok? =
      Enum.any?(get_req_header(conn, "origin"), fn origin ->
        case URI.parse(origin) do
          %URI{scheme: scheme, host: host, port: port} ->
            scheme == expected_origin.scheme and host in ["127.0.0.1", expected_origin.host] and
              port == expected_origin.port
        end
      end)

    with true <- origin_ok?,
         encounter when is_binary(encounter) <- get_session(conn, :lab_encounter),
         actor when is_binary(actor) <- get_session(conn, :exam_actor),
         true <- Records.member?(Postgres, encounter, actor, :patient) do
      WebSockAdapter.upgrade(conn, __MODULE__, %{encounter: encounter, actor: actor},
        max_frame_size: 1936,
        timeout: 15_000
      )
    else
      _ -> send_resp(conn, 403, "Patient access required")
    end
  end

  @impl true
  def init(%{encounter: encounter, actor: actor} = state) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    config = Exam.lab()

    with true <- Records.member?(Postgres, encounter, actor, :patient),
         {:ok, _} <- Registry.register(MedFabric.Exam.ActiveCapture, encounter, nil),
         :ok <- File.mkdir_p(config.artifact_dir),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             MedFabric.Exam.Captures,
             {MedEx.Capture, acquisition_id: id, artifact_dir: config.artifact_dir}
           ) do
      Registry.update_value(MedFabric.Exam.ActiveCapture, encounter, fn _ -> pid end)

      Phoenix.PubSub.broadcast(
        MedFabric.Exam.PubSub,
        "preview:" <> encounter,
        {:capture_started, pid}
      )

      {:ok, Map.merge(state, %{capture: pid, id: id, started_at: DateTime.utc_now()})}
    else
      _ -> {:stop, :unauthorized_capture, state}
    end
  end

  @impl true
  def handle_in({<<index::unsigned-big-64, pcm::binary>>, [opcode: :binary]}, state) do
    case MedEx.Capture.push(state.capture, index, pcm) do
      :ok -> {:push, {:text, "ack"}, state}
      {:error, _} -> {:stop, :invalid_capture, state}
    end
  end

  def handle_in({"finish", [opcode: :text]}, state) do
    with true <- Records.member?(Postgres, state.encounter, state.actor, :patient),
         {:ok, artifact} <- MedEx.Capture.finish(state.capture),
         {:ok, evidence} <- Evidence.recording(artifact, state.actor, state.started_at),
         :ok <- Records.ready(Postgres, state.encounter, state.id, evidence) do
      Exam.announce(Exam.lab())
      {:stop, :normal, 1000, {:text, "ready"}, state}
    else
      _ -> {:stop, :capture_failed, state}
    end
  end

  def handle_in(_, state), do: {:stop, :invalid_capture, state}

  @impl true
  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(_, %{capture: pid}) do
    DynamicSupervisor.terminate_child(MedFabric.Exam.Captures, pid)
    :ok
  end

  def terminate(_, _), do: :ok
end
