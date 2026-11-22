defmodule MedFabric.ExamWeb.ExamLive do
  @moduledoc false
  use Phoenix.LiveView

  alias MedFabric.Exam.Demo
  alias MedFabric.ExamWeb.Endpoint

  @impl true
  def mount(%{"encounter_id" => id}, %{"lab_encounter" => id}, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(MedFabric.Exam.PubSub, Demo.topic(id))
    token = Phoenix.Token.sign(Endpoint, "exam-preview", id)
    {:ok, socket |> assign(view: Demo.snapshot(), token: token, error: nil)}
  end

  def mount(_params, _session, socket), do: {:ok, redirect(socket, to: "/")}

  @impl true
  def handle_info(:exam_changed, socket), do: {:noreply, assign(socket, :view, Demo.snapshot())}

  @impl true
  def handle_event("capture", _params, socket), do: result(socket, Demo.capture())
  def handle_event("deliver", _params, socket), do: result(socket, Demo.deliver())

  def handle_event("accept", %{"digest" => digest}, socket) do
    result(socket, Demo.accept(digest, "lab-clinician"))
  end

  defp result(socket, :ok), do: {:noreply, assign(socket, view: Demo.snapshot(), error: nil)}

  defp result(socket, {:error, _reason}),
    do: {:noreply, assign(socket, :error, "The action failed. Please retry.")}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="exam-screen">
      <h1>Encounter {@view.encounter_id}</h1>
      <section
        id="live-preview"
        phx-hook="MedExSessionHook"
        phx-update="ignore"
        data-encounter-id={@view.encounter_id}
        data-session-id={@view.session.id}
        data-token={@token}
      >
        <h2>Live preview</h2>
        <audio autoplay></audio>
        <button id="preview-play" type="button">Play preview</button>
        <button id="preview-disconnect" type="button">Disconnect preview</button>
        <button id="preview-reconnect" type="button">Reconnect preview</button>
      </section>

      <button :if={!@view.capture && !@view.artifact && !@view.record} id="start-capture" type="button" phx-click="capture">
        Start capture
      </button>
      <p :if={@view.capture} id="capture-active">Recording in progress</p>
      <p :if={@view.error} role="alert">Capture failed.</p>

      <section :if={@view.artifact || @view.record} id="recording">
        <h2>Recording</h2>
        <audio id="recording-audio" controls src={"/encounters/#{@view.encounter_id}/recording"}></audio>
        <p id="recording-continuity">{(@view.artifact || @view.record.observation).continuity}</p>
        <button :if={@view.artifact && !@view.record} id="accept-recording"
          type="button" phx-click="accept" phx-value-digest={@view.artifact.artifact_sha256}>
          Accept recording
        </button>
      </section>

      <section :if={@view.record} id="accepted-observation">
        <p id="observation-id">{@view.record.observation.observation_id}</p>
        <p id="outbox-status">{@view.record.outbox.status}</p>
        <p id="remote-reference">{Map.get(@view.record.outbox, :remote_ref)}</p>
        <button id="deliver-recording" type="button" phx-click="deliver">Verify FHIR delivery</button>
      </section>

      <p :if={@error} role="alert">{@error}</p>
    </main>
    """
  end
end
