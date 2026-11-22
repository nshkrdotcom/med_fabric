defmodule MedFabric.ExamWeb.ExamLive do
  @moduledoc """
  Minimal exam LiveView owned by `med_fabric/apps/exam`.

  Renders the encounter screen, mounts `:med_ex`'s browser WebRTC hook inside a
  `phx-update="ignore"` container so LiveView updates preserve the peer
  connection, displays live preview status separately from finalized recording
  continuity, and commits explicit clinician acceptance atomically via
  `MedFabric.Store.OutboxStore`.
  """

  use Phoenix.LiveView

  alias MedFabric.Domain.Encounter
  alias MedFabric.Exam
  alias MedFabric.Store.OutboxStore

  @impl true
  def mount(%{"encounter_id" => encounter_id}, session, socket) do
    {:ok, encounter} =
      Encounter.new(encounter_id)
      |> Encounter.request_acquisition(Map.get(session, "acquisition_id", "acq_1"))

    store = Map.get(session, "store") || Application.get_env(:mf_exam, :outbox_store)

    socket =
      socket
      |> assign(:encounter, encounter)
      |> assign(:session_id, Map.get(session, "session_id", "sess_#{encounter_id}"))
      |> assign(:clinician_id, Map.get(session, "clinician_id", "clin_1"))
      |> assign(:store, store)
      |> assign(:accepted_record, nil)
      |> assign(:error_message, nil)

    {:ok, socket}
  end

  @impl true
  def handle_info({:med_ex_effects, effects}, socket) when is_list(effects) do
    next_encounter = Exam.ingest_effects(socket.assigns.encounter, effects)
    {:noreply, assign(socket, :encounter, next_encounter)}
  end

  @impl true
  def handle_event("accept_acquisition", %{"acquisition_id" => acq_id, "sha256" => sha}, socket) do
    case Encounter.accept_acquisition(
           socket.assigns.encounter,
           acq_id,
           sha,
           socket.assigns.clinician_id
         ) do
      {:ok, next_encounter, acceptance} ->
        record = maybe_commit(socket.assigns.store, acceptance)

        {:noreply,
         socket
         |> assign(:encounter, next_encounter)
         |> assign(:accepted_record, record || acceptance)
         |> assign(:error_message, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error_message, "Acceptance blocked: #{reason}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="exam-screen" data-encounter-id={@encounter.id}>
      <h1>Encounter <%= @encounter.id %></h1>

      <section
        id="med-ex-webrtc-preview"
        phx-hook="MedExSessionHook"
        phx-update="ignore"
        data-encounter-id={@encounter.id}
        data-session-id={@session_id}
        data-hook-src="/med_ex/session_hook.js"
      >
        <audio id="med-ex-preview-audio" autoplay></audio>
      </section>

      <section id="preview-status">
        <%= for {{:preview_stream, stream_id}, report} <- @encounter.transient_preview_state do %>
          <p data-preview-stream={stream_id}>
            Preview (<%= stream_id %>): <%= report.continuity %>
          </p>
        <% end %>
      </section>

      <section id="review-candidates">
        <%= for {acq_id, cand} <- @encounter.review_candidates do %>
          <article data-candidate={acq_id}>
            <span>Recording <%= acq_id %>: <%= cand.continuity %> (<%= cand.status %>)</span>
            <%= if cand.status == :ready_for_review do %>
              <button
                type="button"
                phx-click="accept_acquisition"
                phx-value-acquisition_id={acq_id}
                phx-value-sha256={cand.artifact_sha256}
              >
                Accept Recording
              </button>
            <% end %>
          </article>
        <% end %>
      </section>

      <%= if @accepted_record do %>
        <section id="accepted-observation">
          Accepted: <%= @accepted_record.observation.observation_id %>
        </section>
      <% end %>

      <%= if @error_message do %>
        <p id="exam-error"><%= @error_message %></p>
      <% end %>
    </main>
    """
  end

  defp maybe_commit(nil, _acceptance), do: nil

  defp maybe_commit(store, acceptance) do
    provenance = %{source_kind: :exam_live, source_ref: "live_review"}
    {:ok, _status, record} = OutboxStore.commit_acceptance(store, acceptance, provenance)
    record
  end
end
