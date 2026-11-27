defmodule MedFabric.ExamWeb.TalkbackChannel do
  @moduledoc "Call-bound cooperative direct-media authority; signaling cannot forcibly stop established P2P transport."
  use Phoenix.Channel
  alias MedFabric.Exam
  alias MedFabric.Store.{Encounters, AcquisitionSessions}
  @registry MedFabric.Exam.AcquisitionRegistry

  def join(
        "talkback:" <> id,
        %{"call_id" => call, "nonce" => nonce, "purpose" => "talkback"},
        %{assigns: %{encounter_id: id, actor: actor, role: role, session: session}} = socket
      ) do
    with true <- AcquisitionSessions.identifier?(call) and AcquisitionSessions.identifier?(nonce),
         {:ok, remaining} <-
           Encounters.authority_remaining(Exam.context().db, session, id, actor, role),
         true <- remaining > 0,
         {:ok, _} <-
           Registry.register(@registry, {:talkback, id, role}, %{
             call: call,
             session: session,
             actor: actor
           }) do
      Phoenix.PubSub.subscribe(Exam.PubSub, "exam:" <> id)

      socket =
        assign(socket,
          call: call,
          grant_until: System.monotonic_time(:millisecond) + remaining,
          grant_timer: nil
        )

      {:ok, grant(socket, nonce, remaining), timer(socket, remaining)}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "unauthorized"}}

  def handle_in(
        "renew",
        %{"call_id" => call, "nonce" => nonce},
        %{assigns: %{call: call}} = socket
      ) do
    with true <- AcquisitionSessions.identifier?(nonce),
         true <- current?(socket),
         {:ok, remaining} <- authority(socket),
         true <- remaining > 0 do
      {:reply, {:ok, grant(socket, nonce, remaining)},
       timer(
         assign(socket, :grant_until, System.monotonic_time(:millisecond) + remaining),
         remaining
       )}
    else
      _ -> end_call(socket, "authority_ended")
    end
  end

  def handle_in(
        "signal",
        %{"type" => type, "id" => call} = payload,
        %{assigns: %{call: call}} = socket
      )
      when type in ["ready", "offer", "answer"] do
    with true <- current?(socket),
         {:ok, remaining} <- authority(socket),
         true <- remaining > 0,
         true <- byte_size(Jason.encode!(payload)) <= 32_768,
         true <- peer_allowed?(socket, type, payload) do
      broadcast_from!(socket, "signal", Map.put(payload, "role", to_string(socket.assigns.role)))
      {:reply, :ok, socket}
    else
      _ -> end_call(socket, "signal_denied")
    end
  end

  def handle_in("close", %{"call_id" => call}, %{assigns: %{call: call}} = socket),
    do: end_call(socket, "closed")

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  def handle_info({:authority_expired, token}, %{assigns: %{grant_timer: {_, token}}} = socket),
    do: end_call(socket, "authority_expired")

  def handle_info(:exam_changed, socket) do
    case authority(socket) do
      {:ok, n} when n > 0 -> {:noreply, socket}
      _ -> end_call(socket, "authority_ended")
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def terminate(_, socket) do
    if socket.assigns[:grant_timer], do: Process.cancel_timer(elem(socket.assigns.grant_timer, 0))
    :ok
  end

  defp authority(socket),
    do:
      Encounters.authority_remaining(
        Exam.context().db,
        socket.assigns.session,
        socket.assigns.encounter_id,
        socket.assigns.actor,
        socket.assigns.role
      )

  defp current?(socket),
    do:
      System.monotonic_time(:millisecond) < socket.assigns.grant_until and
        Registry.lookup(@registry, {:talkback, socket.assigns.encounter_id, socket.assigns.role}) ==
          [
            {self(),
             %{
               call: socket.assigns.call,
               session: socket.assigns.session,
               actor: socket.assigns.actor
             }}
          ]

  defp peer_allowed?(_, "ready", payload), do: Map.keys(payload) -- ~w(type id) == []

  defp peer_allowed?(socket, _, payload) do
    other = if socket.assigns.role == :patient, do: :clinician, else: :patient

    case Registry.lookup(@registry, {:talkback, socket.assigns.encounter_id, other}) do
      [{_, %{call: call, session: session, actor: actor}}] ->
        payload["target"] == call and AcquisitionSessions.identifier?(payload["offer"]) and
          is_binary(payload["sdp"]) and
          match?(
            {:ok, n} when n > 0,
            Encounters.authority_remaining(
              Exam.context().db,
              session,
              socket.assigns.encounter_id,
              actor,
              other
            )
          )

      _ ->
        false
    end
  end

  defp grant(socket, nonce, remaining),
    do: %{
      call_id: socket.assigns.call,
      session: socket.assigns.session,
      nonce: nonce,
      purpose: "talkback",
      peer_scope: if(socket.assigns.role == :patient, do: "clinician", else: "patient"),
      remaining_ms: remaining
    }

  defp timer(socket, remaining) do
    if socket.assigns.grant_timer, do: Process.cancel_timer(elem(socket.assigns.grant_timer, 0))
    token = make_ref()

    assign(
      socket,
      :grant_timer,
      {Process.send_after(self(), {:authority_expired, token}, remaining), token}
    )
  end

  defp end_call(socket, reason) do
    broadcast!(socket, "authority_end", %{call_id: socket.assigns.call, reason: reason})
    {:stop, :normal, socket}
  end
end
