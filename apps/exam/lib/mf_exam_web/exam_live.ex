defmodule MedFabric.ExamWeb.ExamLive do
  @moduledoc false
  use Phoenix.LiveView
  alias MedFabric.Exam
  alias MedFabric.Store.{Encounters,Records}
  def mount(%{"encounter_id"=>id},%{"lab_encounter"=>id,"exam_actor"=>actor,"exam_role"=>role,"exam_session"=>session},socket) when role in ["patient","clinician"] do
    role=if role == "patient",do: :patient,else: :clinician
    trusted=not connected?(socket) or MedFabric.ExamWeb.ProxyIdentity.matches?(get_connect_info(socket,:x_headers)||[],actor,Exam.lab())
    if trusted and Encounters.session_authorized?(Exam.context().db,session,id,actor,role,:read) do
      if connected?(socket),do: Phoenix.PubSub.subscribe(MedFabric.Exam.PubSub,"exam:"<>id)
      token=Phoenix.Token.sign(MedFabric.ExamWeb.Endpoint,"exam-talkback",{id,actor,role,session,"talkback"})
      {:ok,socket |> assign(encounter: id,actor: actor,role: role,session: session,token: token,error: nil,records: []) |> refresh()}
    else {:ok,redirect(socket,to: "/")} end
  end
  def mount(_,_,socket),do: {:ok,redirect(socket,to: "/")}
  def handle_info(:exam_changed,socket),do: {:noreply,refresh(socket)}
  def handle_event(event,params,%{assigns: a}=socket) do
    if Encounters.session_authorized?(Exam.context().db,a.session,a.encounter,a.actor,a.role,:read),
      do: event(event,params,socket),else: {:noreply,redirect(socket,to: "/")}
  end
  defp event("pulse",%{"value"=>value},%{assigns: %{role: :clinician}=a}=socket) when is_binary(value) and byte_size(value)<=20 do
    case Integer.parse(value) do {n,""}->result(socket,Exam.pulse(a.encounter,a.actor,n)); _->result(socket,{:error,:invalid_value}) end
  end
  defp event("accept",%{"id"=>id,"request_id"=>request},%{assigns: %{role: :clinician}=a}=socket),do: result(socket,Exam.accept(a.encounter,id,a.actor,request))
  defp event("deliver",%{"id"=>id},%{assigns: %{role: :clinician}=a}=socket),do: result(socket,Exam.deliver(a.encounter,id,a.actor))
  defp event(_,_,socket),do: {:noreply,socket}
  defp result(socket,result),do: {:noreply,socket |> refresh() |> assign(:error,if(match?({:ok,_},result) or result == :ok,do: nil,else: "Action refused"))}
  defp refresh(%{assigns: %{role: :clinician}=a}=socket) do
    if Encounters.session_authorized?(Exam.context().db,a.session,a.encounter,a.actor,a.role,:read) do
      case Records.list(Exam.context().db,a.encounter,a.actor) do {:ok,rows}->assign(socket,:records,rows); _->assign(socket,:error,"Evidence unavailable") end
    else assign(socket,records: [],error: "Session authority ended") end
  end
  defp refresh(socket),do: socket
  def render(assigns) do
    ~H"""
    <main>
      <h1>Encounter {@encounter}</h1>
      <p :if={@error} role="alert">{@error}</p>
      <a :if={@role == :clinician} href={"/encounters/#{@encounter}/devices"}>Acquisitions and verified review</a>
      <section id="talkback" phx-update="ignore" phx-hook="Talkback" data-encounter={@encounter} data-role={@role} data-token={@token} data-session={@session}>
        <h2>Conversation</h2><select data-input><option value="">System default</option></select>
        <button type="button">Join conversation</button><audio autoplay controls></audio><p role="status"></p>
      </section>
      <section :if={@role == :patient} id="capture" phx-update="ignore" phx-hook="Capture" data-encounter={@encounter}>
        <h2>Microphone acquisition</h2><select data-input><option value="">System default</option></select>
        <button type="button" data-start>Start capture</button><button type="button" data-finish disabled>Finish capture</button><p role="status"></p>
        <p>Current-page recording only. Loss of the page interrupts acquisition; verified committed evidence is preserved.</p>
      </section>
      <section :if={@role == :clinician}>
        <h2>Manual pulse</h2><form phx-submit="pulse"><label>Pulse /min <input name="value" type="number" min="0" required /></label><button>Record manual evidence</button></form>
        <article :for={record <- @records} id={"native-manual-#{record.id}"} phx-hook="NativeReview" data-id={record.id} data-observation={record.observation} data-delivery={record.status} data-remote-ref={record.remote}>
          <h3>Manual pulse {record.evidence["value"]["mantissa"]} /min</h3>
          <p>{record.evidence["effective_at"]}</p>
          <button :if={!record.decision} type="button" data-accept>Accept clinical evidence</button>
          <p :if={record.decision}>Clinically accepted</p>
          <p :if={record.status}>Export: {record.status}</p>
          <p :if={record.remote}>Remote observation: {record.remote}</p>
          <button :if={record.decision && record.status != "confirmed"} phx-click="deliver" phx-value-id={record.observation}>Request delivery</button>
        </article>
      </section>
    </main>
    """
  end
end
