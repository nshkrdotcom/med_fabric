defmodule MedFabric.ExamWeb.ExamLive do
  @moduledoc false
  use Phoenix.LiveView

  alias MedFabric.Exam
  alias MedFabric.ExamWeb.Endpoint
  alias MedFabric.Store.{Postgres, Records}

  @impl true
  def mount(
        %{"encounter_id" => id},
        %{"lab_encounter" => id, "exam_actor" => actor, "exam_role" => role},
        socket
      )
      when role in ["patient", "clinician"] do
    role = if role == "patient", do: :patient, else: :clinician

    trusted = !connected?(socket) or MedFabric.ExamWeb.ProxyIdentity.matches?(
      get_connect_info(socket, :x_headers) || [], actor, Exam.lab())
    if trusted and Records.member?(Postgres, id, actor, role) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(MedFabric.Exam.PubSub, "exam:" <> id)
      token = Phoenix.Token.sign(Endpoint, "exam-preview", {id, actor, role})

      {:ok,
       socket
       |> assign(
         encounter: id,
         actor: actor,
         role: role,
         token: token,
         error: nil,
         delivering: nil,
         accepting: nil,
         records: []
       )
       |> refresh()}
    else
      {:ok, redirect(socket, to: "/")}
    end
  end

  def mount(_, _, socket), do: {:ok, redirect(socket, to: "/")}

  @impl true
  def handle_info(:exam_changed, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("pulse", %{"value" => value}, %{assigns: %{role: :clinician} = a} = socket) do
    case Integer.parse(value) do
      {number, ""} -> result(socket, Exam.pulse(a.encounter, a.actor, number))
      _ -> result(socket, {:error, :invalid_pulse_rate})
    end
  end

  def handle_event("accept", %{"id" => id}, %{assigns: %{role: :clinician, accepting: nil} = a} = socket) do
    %{encounter: encounter, actor: actor} = a
    {:noreply, socket |> assign(:accepting, id) |> start_async(:accept, fn -> Exam.accept(encounter, id, actor) end)}
  end

  def handle_event(
        "deliver",
        %{"id" => id},
        %{assigns: %{role: :clinician, delivering: nil} = a} = socket
      ) do
    {:noreply,
     socket
     |> assign(:delivering, id)
     |> start_async(:deliver, fn -> Exam.deliver(a.encounter, id, a.actor) end)}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:accept, {:ok, outcome}, socket), do: result(assign(socket, :accepting, nil), outcome)
  def handle_async(:accept, {:exit, _}, socket), do: result(assign(socket, :accepting, nil), {:error, :accept_failed})

  def handle_async(:deliver, {:ok, outcome}, socket),
    do: result(assign(socket, :delivering, nil), outcome)

  def handle_async(:deliver, {:exit, _}, socket),
    do: result(assign(socket, :delivering, nil), {:error, :delivery_failed})

  defp result(socket, outcome) do
    error = if outcome == :ok, do: nil, else: "The action failed."
    {:noreply, socket |> refresh() |> assign(:error, error)}
  end

  defp refresh(%{assigns: %{role: :clinician, encounter: enc}} = socket) do
    case Records.list(Postgres, enc) do
      {:ok, records} -> assign(socket, :records, records)
      {:error, _} -> assign(socket, :error, "Records unavailable.")
    end
  end

  defp refresh(socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>Encounter {@encounter}</h1>
      <section id="talkback" phx-update="ignore" phx-hook="Talkback"
        data-encounter={@encounter} data-role={@role} data-token={@token}>
        <h2>Conversation</h2>
        <label>Conversation microphone
          <select data-input><option value="">System default</option></select>
        </label>
        <button type="button">Join conversation</button>
        <audio autoplay controls></audio>
        <p role="status"></p>
      </section>

      <section :if={@role == :patient} id="capture" data-encounter={@encounter} phx-hook="Capture" phx-update="ignore">
        <h2>Diagnostic capture</h2>
        <label>Diagnostic input
          <select data-input><option value="">System default</option></select>
        </label>
        <button type="button" data-start>Start capture</button>
        <button type="button" data-finish disabled>Finish capture</button>
        <button type="button" data-check hidden>Check recording outcome</button>
        <p role="status"></p>
      </section>

      <section :if={@role == :clinician} id="live-preview" data-state="disconnected"
        phx-hook="MedExSessionHook" phx-update="ignore" data-encounter-id={@encounter}
        data-session-id={Exam.session_id(@encounter)} data-token={@token}>
        <h2>Live diagnostic preview</h2>
        <p role="status">Disconnected</p>
        <audio autoplay controls></audio>
        <button id="preview-play" type="button">Play preview</button>
        <button id="preview-disconnect" type="button">Disconnect preview</button>
        <button id="preview-reconnect" type="button">Reconnect preview</button>
      </section>

      <form :if={@role == :clinician} phx-submit="pulse">
        <label>Measured pulse rate (beats per minute)
          <input type="number" name="value" min="1" required />
        </label>
        <button>Record pulse</button>
      </form>

      <section :for={row <- @records} id={"evidence-" <> row.id}>
        <h2>{if row.evidence["kind"] == "pulse_rate", do: "Pulse rate", else: "Recording"}</h2>
        <p :if={row.evidence["kind"] == "pulse_rate"}>{row.evidence["value"]} beats/minute</p>
        <p :if={row.evidence["kind"] == "audio_pcm16_wav"}>
          {get_in(row.evidence, ["provenance", "input", "label"]) || "Diagnostic input"}
          · {Float.round(row.evidence["sample_count"] / row.evidence["sample_rate_hz"], 2)} s
          · First frame received <time datetime={row.evidence["effective_at"]}>{row.evidence["effective_at"]}</time>
        </p>
        <audio :if={row.evidence["kind"] == "audio_pcm16_wav"} controls
          src={"/encounters/#{@encounter}/recordings/#{row.id}"}></audio>
        <p :if={row.conflict} role="alert">Conflicting evidence</p>
        <button :if={!row.actor && !row.conflict} disabled={@accepting != nil} phx-click="accept" phx-value-id={row.id}>Accept</button>
        <button :if={row.actor && !row.remote} disabled={@delivering != nil}
          phx-click="deliver" phx-value-id={row.id}>Deliver to FHIR</button>
        <p :if={row.remote}>{row.remote}</p>
        <p :if={row.error} role="alert">Delivery failed. Retry when ready.</p>
      </section>
      <p :if={@error} role="alert">{@error}</p>
    </main>
    """
  end
end
