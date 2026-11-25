defmodule MedFabric.ExamWeb.SignalingChannel do
  @moduledoc false
  use Phoenix.Channel

  alias MedEx.{Capture, Preview}
  alias MedFabric.Exam

  @impl true
  def join("signaling:" <> encounter_id, %{"connection_id" => connection_id}, socket)
      when is_binary(connection_id) and byte_size(connection_id) == 36 do
    with :clinician <- socket.assigns.role,
         ^encounter_id <- socket.assigns.encounter_id,
         true <- Exam.member?(encounter_id, socket.assigns.actor, :clinician) do
      session_id = Exam.session_id(encounter_id)

      {:ok, %{session_id: session_id},
       assign(socket,
         peer: nil,
         capture: nil,
         sequence: 0,
         clock: nil,
         connected: false
       )}
    else
      _ -> {:error, %{reason: "unauthorized_encounter"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "invalid_connection"}}

  @impl true
  def handle_in("offer", %{"sdp" => sdp}, %{assigns: %{peer: nil}} = socket)
      when is_binary(sdp) and byte_size(sdp) < 32_768 do
    ice = Exam.ICE.config(socket.assigns.actor, Exam.lab().turn)
    policy = if ice.iceTransportPolicy == "relay", do: :relay, else: :all

    case Preview.answer(sdp, ice_servers: ice.iceServers, ice_transport_policy: policy) do
      {:ok, peer, answer} ->
        {:reply, {:ok, %{sdp: answer}}, assign(socket, :peer, peer)}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "negotiation_failed"}}, socket}
    end
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  @impl true
  def handle_info(
        {:ex_webrtc, pid, {:connection_state_change, :connected}},
        %{assigns: %{peer: %{pid: pid}, encounter_id: encounter, connected: false}} = socket
      ) do
    Phoenix.PubSub.subscribe(MedFabric.Exam.PubSub, "preview:" <> encounter)

    case Exam.Recordings.active(encounter) do
      capture when is_pid(capture) -> send(self(), {:capture_started, capture})
      _ -> :ok
    end

    {:noreply, assign(socket, :connected, true)}
  end

  def handle_info({:capture_started, capture}, %{assigns: %{connected: true}} = socket) do
    case Capture.subscribe(capture) do
      :ok ->
        {:noreply, assign(socket, :capture, capture)}

      {:error, _} ->
        push(socket, "preview_failed", %{})
        {:noreply, socket}
    end
  catch
    :exit, _ -> {:noreply, socket}
  end

  def handle_info(
        {:med_ex_preview, capture, index, frame},
        %{assigns: %{capture: capture, peer: peer, sequence: sequence}} = socket
      ) do
    clock = Preview.Clock.advance(socket.assigns.clock, capture, index)
    Preview.send_opus(peer, frame, sequence, clock.tick)
    Capture.demand(capture)
    {:noreply, assign(socket, sequence: sequence + 1, clock: clock)}
  end

  def handle_info({:med_ex_preview_replaced, capture}, %{assigns: %{capture: capture}} = socket) do
    push(socket, "preview_replaced", %{})
    {:noreply, assign(socket, :capture, nil)}
  end

  def handle_info({:med_ex_preview_failed, capture, _}, %{assigns: %{capture: capture}} = socket) do
    push(socket, "preview_failed", %{})
    {:noreply, assign(socket, :capture, nil)}
  end

  def handle_info(
        {:ex_webrtc, pid, {:connection_state_change, state}},
        %{assigns: %{peer: %{pid: pid}}} = socket
      )
      when state in [:failed, :closed],
      do: {:stop, :normal, socket}

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if peer = socket.assigns[:peer], do: Preview.close(peer)
    :ok
  end
end
