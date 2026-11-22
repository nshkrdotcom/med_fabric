defmodule MedFabric.ExamWeb.SignalingChannel do
  @moduledoc false
  use Phoenix.Channel

  alias MedFabric.Exam.Demo
  alias MedRTC.Preview

  @impl true
  def join("signaling:" <> encounter_id, %{"connection_id" => connection_id}, socket)
      when is_binary(connection_id) and byte_size(connection_id) == 36 do
    with ^encounter_id <- socket.assigns.encounter_id,
         %{encounter_id: ^encounter_id} <- Application.get_env(:mf_exam, :lab) do
      session_id = Demo.snapshot().session.id
      {:ok, %{session_id: session_id}, assign(socket, :peer, nil)}
    else
      _ -> {:error, %{reason: "unauthorized_encounter"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "invalid_connection"}}

  @impl true
  def handle_in("offer", %{"sdp" => sdp}, %{assigns: %{peer: nil}} = socket)
      when is_binary(sdp) and byte_size(sdp) < 32_768 do
    case Preview.answer(sdp) do
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
        %{assigns: %{peer: %{pid: pid}, encounter_id: encounter_id}} = socket
      ) do
    Phoenix.PubSub.subscribe(MedFabric.Exam.PubSub, Demo.preview_topic(encounter_id))
    {:noreply, socket}
  end

  def handle_info({:preview_frame, index, frame}, socket) do
    Preview.send_opus(socket.assigns.peer, frame, index)
    {:noreply, socket}
  end

  def handle_info(
        {:ex_webrtc, pid, {:connection_state_change, state}},
        %{assigns: %{peer: %{pid: pid}}} = socket
      )
      when state in [:failed, :closed],
      do: {:stop, :normal, socket}

  def handle_info({:ex_webrtc, _pid, _event}, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if peer = socket.assigns[:peer], do: Preview.close(peer)
    :ok
  end
end
