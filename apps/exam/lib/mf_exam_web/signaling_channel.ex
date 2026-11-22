defmodule MedFabric.ExamWeb.SignalingChannel do
  @moduledoc """
  Authenticated Phoenix Channel exchanging WebRTC SDP offers/answers, ICE
  candidates, and reconnect `connection_id` lifecycles with `:med_ex`'s
  `MedRTC.SessionServer`.

  `apps/exam` authorizes every connection against the encounter's
  `encounter_ref`, while `:med_ex` owns the live `session_id` and media peer.
  """

  use Phoenix.Channel

  alias MedRTC.SessionServer
  alias MedWeb.Signaling

  @impl true
  def join("signaling:" <> encounter_ref, params, socket) do
    with ^encounter_ref <- socket.assigns[:authorized_encounter_ref],
         connection_id when is_binary(connection_id) and connection_id != "" <-
           Map.get(params, "connection_id"),
         session_server when not is_nil(session_server) <- resolve_session(encounter_ref) do
      t_ms = Map.get(params, "t_ms", 0)
      clinician_id = socket.assigns.clinician_id

      {session, _effects} =
        SessionServer.dispatch(
          session_server,
          Signaling.to_session_event({:join, clinician_id, connection_id, :clinician, t_ms})
        )

      socket =
        socket
        |> assign(:encounter_ref, encounter_ref)
        |> assign(:connection_id, connection_id)
        |> assign(:session_server, session_server)
        |> assign(:session_id, session.id)

      {:ok, %{session_id: session.id, connection_id: connection_id}, socket}
    else
      _ -> {:error, %{reason: "unauthorized_encounter"}}
    end
  end

  @impl true
  def handle_in("sdp_offer", %{"sdp" => sdp}, socket) when is_binary(sdp) do
    broadcast_from!(socket, "sdp_offer", %{
      connection_id: socket.assigns.connection_id,
      clinician_id: socket.assigns.clinician_id,
      sdp: sdp
    })

    {:reply, {:ok, %{relayed: :sdp_offer, session_id: socket.assigns.session_id}}, socket}
  end

  def handle_in("sdp_answer", %{"sdp" => sdp}, socket) when is_binary(sdp) do
    broadcast_from!(socket, "sdp_answer", %{
      connection_id: socket.assigns.connection_id,
      clinician_id: socket.assigns.clinician_id,
      sdp: sdp
    })

    {:reply, {:ok, %{relayed: :sdp_answer, session_id: socket.assigns.session_id}}, socket}
  end

  def handle_in("ice_candidate", %{"candidate" => candidate}, socket) when is_binary(candidate) do
    broadcast_from!(socket, "ice_candidate", %{
      connection_id: socket.assigns.connection_id,
      candidate: candidate
    })

    {:reply, {:ok, %{relayed: :ice_candidate}}, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if server = socket.assigns[:session_server] do
      if is_pid(server) and Process.alive?(server) do
        SessionServer.dispatch(
          server,
          Signaling.to_session_event(
            {:leave, socket.assigns.clinician_id, socket.assigns.connection_id,
             System.monotonic_time(:millisecond) |> abs()}
          )
        )
      end
    end

    :ok
  end

  @doc """
  Registers a `MedRTC.SessionServer` pid for an `encounter_ref` in the exam's
  in-memory session registry (used by `SignalingChannel` and `ExamLive`).
  """
  @spec register_session(String.t(), pid()) :: :ok
  def register_session(encounter_ref, session_pid)
      when is_binary(encounter_ref) and is_pid(session_pid) do
    sessions = Application.get_env(:mf_exam, :active_sessions, %{})
    Application.put_env(:mf_exam, :active_sessions, Map.put(sessions, encounter_ref, session_pid))
    :ok
  end

  defp resolve_session(encounter_ref) do
    :mf_exam
    |> Application.get_env(:active_sessions, %{})
    |> Map.get(encounter_ref)
  end
end
