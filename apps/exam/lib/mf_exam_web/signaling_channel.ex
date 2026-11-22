defmodule MedFabric.ExamWeb.SignalingChannel do
  @moduledoc false
  use Phoenix.Channel

  alias MedFabric.Exam
  alias MedRTC.Preview

  @impl true
  def join("signaling:" <> encounter_id, %{"connection_id" => connection_id}, socket)
      when is_binary(connection_id) and byte_size(connection_id) == 36 do
    with ^encounter_id <- socket.assigns.encounter_id,
         %{encounter_id: ^encounter_id} <- Application.get_env(:mf_exam, :lab) do
      session_id = Exam.session_id(encounter_id)

      {:ok, %{session_id: session_id},
       assign(socket,
         peer: nil,
         subscribed: false,
         sequence: 0,
         media: nil
       )}
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
        %{assigns: %{peer: %{pid: pid}, subscribed: false, encounter_id: encounter_id}} = socket
      ) do
    Phoenix.PubSub.subscribe(MedFabric.Exam.PubSub, "preview:" <> encounter_id)
    {:noreply, assign(socket, :subscribed, true)}
  end

  def handle_info(
        {:preview_frame, generation, index, frame},
        %{assigns: %{peer: %Preview{} = peer, media: media, sequence: sequence}} = socket
      ) do
    case media do
      {^generation, previous, _tick} when index <= previous ->
        {:noreply, socket}

      _ ->
        tick = media_tick(media, generation, index)
        Preview.send_opus(peer, frame, sequence, tick)
        {:noreply, assign(socket, sequence: sequence + 1, media: {generation, index, tick})}
    end
  end

  def handle_info(
        {:ex_webrtc, pid, {:connection_state_change, state}},
        %{assigns: %{peer: %{pid: pid}}} = socket
      )
      when state in [:failed, :closed],
      do: {:stop, :normal, socket}

  def handle_info({:preview_frame, _, _, _}, socket), do: {:noreply, socket}

  def handle_info({:ex_webrtc, _pid, _event}, socket), do: {:noreply, socket}

  defp media_tick(nil, _generation, _index), do: 0
  defp media_tick({generation, previous, tick}, generation, index), do: tick + index - previous
  defp media_tick({_previous_generation, _previous, tick}, _generation, _index), do: tick + 1

  @impl true
  def terminate(_reason, socket) do
    if peer = socket.assigns[:peer], do: Preview.close(peer)
    :ok
  end
end
