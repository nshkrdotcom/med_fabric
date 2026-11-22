defmodule MedFabric.ExamWeb.UserSocket do
  @moduledoc """
  Authenticated Phoenix socket for WebRTC SDP/ICE signaling in `apps/exam`.
  """

  use Phoenix.Socket

  channel "signaling:*", MedFabric.ExamWeb.SignalingChannel

  @impl true
  def connect(%{"clinician_id" => clinician_id, "encounter_ref" => encounter_ref}, socket, _info)
      when is_binary(clinician_id) and clinician_id != "" and
             is_binary(encounter_ref) and encounter_ref != "" do
    socket =
      socket
      |> assign(:clinician_id, clinician_id)
      |> assign(:authorized_encounter_ref, encounter_ref)

    {:ok, socket}
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "exam_clinician:#{socket.assigns.clinician_id}"
end
