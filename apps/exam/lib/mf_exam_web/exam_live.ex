defmodule MedFabric.ExamWeb.ExamLive do
  @moduledoc false
  use Phoenix.LiveView

  alias MedFabric.Exam
  alias MedFabric.Exam.CaptureRunner
  alias MedFabric.ExamWeb.Endpoint

  @impl true
  def mount(%{"encounter_id" => id}, %{"lab_encounter" => id}, socket) do
    if Exam.lab().encounter_id == id do
      if connected?(socket), do: Phoenix.PubSub.subscribe(MedFabric.Exam.PubSub, "exam:" <> id)
      token = Phoenix.Token.sign(Endpoint, "exam-preview", id)

      {:ok,
       socket
       |> assign(view: Exam.snapshot(Exam.lab()), encounter_id: id, token: token, error: nil)}
    else
      {:ok, redirect(socket, to: "/")}
    end
  end

  def mount(_params, _session, socket), do: {:ok, redirect(socket, to: "/")}

  @impl true
  def handle_info(:exam_changed, socket),
    do: {:noreply, assign(socket, :view, Exam.snapshot(Exam.lab()))}

  @impl true
  def handle_event("capture", _params, socket), do: result(socket, CaptureRunner.start())

  def handle_event("deliver", _params, socket),
    do: {:noreply, start_async(socket, :delivery, fn -> Exam.deliver(Exam.lab()) end)}

  def handle_event("accept", %{"digest" => digest}, socket) do
    result(socket, Exam.accept(Exam.lab(), digest))
  end

  @impl true
  def handle_async(:delivery, {:ok, result}, socket), do: result(socket, result)
  def handle_async(:delivery, {:exit, _}, socket), do: result(socket, {:error, :delivery_failed})

  defp result(socket, :ok),
    do: {:noreply, assign(socket, view: Exam.snapshot(Exam.lab()), error: nil)}

  defp result(socket, {:error, _reason}),
    do: {:noreply, assign(socket, :error, "The action failed. Please retry.")}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="exam-screen">
      <h1>Encounter {@encounter_id}</h1>
      <section
        id="live-preview"
        data-state="disconnected" phx-hook="MedExSessionHook"
        phx-update="ignore"
        data-encounter-id={@encounter_id}
        data-session-id={Exam.session_id(@encounter_id)}
        data-token={@token}
      >
        <h2>Live preview</h2>
        <style>#live-preview::before {content: attr(data-state) " " attr(data-error);display:block}</style>
        <audio autoplay></audio>
        <button id="preview-play" type="button">Play preview</button>
        <button id="preview-disconnect" type="button">Disconnect preview</button>
        <button id="preview-reconnect" type="button">Reconnect preview</button>
      </section>

      <button :if={!@view.capture && !@view.row} id="start-capture" type="button" phx-click="capture">
        Start capture
      </button>
      <p :if={@view.capture} id="capture-active">Recording in progress</p>
      <p :if={@view.error} role="alert">Capture failed.</p>

      <section :if={@view.row} id="recording">
        <h2>Recording</h2>
        <p :if={@view.row.conflict} role="alert">Conflicting recording evidence</p>
        <audio id="recording-audio" controls src={"/encounters/#{@encounter_id}/recording"}></audio>
        <p id="recording-continuity">{@view.row.metadata["continuity"]}</p>
        <button :if={!@view.row.accepted_by && !@view.row.conflict} id="accept-recording"
          type="button" phx-click="accept" phx-value-digest={@view.row.metadata["file_sha256"]}>
          Accept recording
        </button>
      </section>

      <section :if={@view.row && @view.row.accepted_by} id="accepted-observation">
        <p id="observation-id">obs:{@encounter_id}:circor-1</p>
        <p id="outbox-status">{if @view.row.remote_ref, do: "delivered", else: "pending"}</p>
        <p id="remote-reference">{@view.row.remote_ref}</p>
        <button id="deliver-recording" type="button" phx-click="deliver">Deliver to FHIR</button>
      </section>

      <p :if={@error} role="alert">{@error}</p>
    </main>
    """
  end
end
