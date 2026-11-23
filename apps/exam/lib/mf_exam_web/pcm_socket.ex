defmodule MedFabric.ExamWeb.PCMSocket do
  @moduledoc false
  @behaviour WebSock

  alias MedFabric.Exam
  alias MedFabric.Exam.Recordings
  alias MedFabric.ExamWeb.Endpoint
  alias MedFabric.Store.Records

  def upgrade(conn, _opts) do
    import Plug.Conn
    expected = Endpoint.url() |> URI.parse()

    origin_ok? =
      Enum.any?(get_req_header(conn, "origin"), fn value ->
        origin = URI.parse(value)

        origin.scheme == expected.scheme and origin.port == expected.port and
          (origin.host == expected.host or
             (expected.host in ["localhost", "127.0.0.1"] and
                origin.host in ["localhost", "127.0.0.1"]))
      end)

    with true <- origin_ok?,
         "patient" <- get_session(conn, :exam_role),
         encounter when is_binary(encounter) <- get_session(conn, :lab_encounter),
         ^encounter <- conn.path_params["encounter_id"],
         actor when is_binary(actor) <- get_session(conn, :exam_actor),
         true <-
           MedFabric.ExamWeb.ProxyIdentity.matches?(conn.req_headers, actor, Exam.lab()),
         true <- Exam.member?(encounter, actor, :patient) do
      WebSockAdapter.upgrade(conn, __MODULE__, %{encounter: encounter, actor: actor},
        max_frame_size: 1936,
        timeout: 60_000
      )
    else
      _ -> send_resp(conn, 403, "Patient access required")
    end
  end

  @impl true
  def init(%{encounter: encounter, actor: actor} = state) do
    state = Map.put_new_lazy(state, :context, &Exam.context/0)

    case Recordings.admit(encounter, actor, state.context) do
      {:ok, id, pid} ->
        {:push, {:text, Jason.encode!(%{acquisition_id: id})},
         Map.merge(state, %{capture: pid, id: id, source: nil})}

      {:error, _} ->
        {:stop, :normal, 1008, {:text, "capture_unavailable"}, state}
    end
  end

  @impl true
  def handle_in({payload, [opcode: :text]}, %{source: nil} = state) do
    case Jason.decode(payload) do
      {:ok, %{"source" => source}} when is_map(source) ->
        {:ok, %{state | source: Map.filter(source, &setting?/1)}}

      _ ->
        invalid(state)
    end
  end

  def handle_in(
        {<<index::unsigned-big-64, pcm::binary>>, [opcode: :binary]},
        %{source: source} = state
      )
      when is_map(source) do
    received_at = if index == 0, do: DateTime.utc_now(:microsecond)

    with :ok <- MedEx.Capture.push(state.capture, index, pcm),
         :ok <- first_frame(state, received_at) do
      {:push, {:text, "ack"}, state}
    else
      _ -> invalid(state)
    end
  end

  def handle_in({"finish", [opcode: :text]}, state) do
    case Recordings.finish(state.encounter, state.id, state.actor, state.capture, state.context) do
      :ok -> {:stop, :normal, 1000, {:text, "ready"}, state}
      _ -> {:stop, :normal, 1011, {:text, "capture_failed"}, state}
    end
  end

  def handle_in(_, state), do: invalid(state)

  defp first_frame(_, nil), do: :ok

  defp first_frame(state, at),
    do: Records.first_frame(state.context.db, state.encounter, state.id, state.source, at)

  defp setting?({"label", value}), do: is_binary(value) and byte_size(value) in 1..255

  defp setting?({key, value}) when key in ~w(sampleRate channelCount contextSampleRate),
    do: is_number(value) and value > 0

  defp setting?({key, value}) when key in ~w(echoCancellation noiseSuppression autoGainControl),
    do: is_boolean(value)

  defp setting?(_), do: false

  defp invalid(state), do: {:stop, :normal, 1008, {:text, "invalid_capture"}, state}

  @impl true
  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(_, %{capture: pid, encounter: encounter, id: id, context: context}) do
    DynamicSupervisor.terminate_child(context.captures, pid)
    Recordings.status(encounter, id, context)
    :ok
  end

  def terminate(_, _), do: :ok
end
