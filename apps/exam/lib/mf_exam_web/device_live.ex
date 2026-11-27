defmodule MedFabric.ExamWeb.DeviceLive do
  @moduledoc false
  use Phoenix.LiveView
  alias MedFabric.Exam
  alias MedFabric.Exam.AcquisitionWorkflow
  alias MedFabric.Store.{DeviceSessions,Encounters}
  def mount(%{"encounter_id"=>enc},%{"lab_encounter"=>enc,"exam_actor"=>actor,"exam_role"=>"clinician","exam_session"=>session},socket) do
    if Encounters.session_authorized?(Exam.context().db,session,enc,actor,:clinician,:read) and (not connected?(socket) or MedFabric.ExamWeb.ProxyIdentity.matches?(get_connect_info(socket,:x_headers)||[],actor,Exam.lab())) do
      if connected?(socket),do: Process.send_after(self(),:refresh,1000)
      {:ok,assign(socket,enc: enc,actor: actor,session: session,devices: DeviceSessions.list(Exam.context().db),rows: AcquisitionWorkflow.list(Exam.context(),enc,actor),bands: %{},message: nil)}
    else {:ok,redirect(socket,to: "/")} end
  end
  def mount(_,_,socket),do: {:ok,redirect(socket,to: "/")}
  def handle_info(:refresh,s) do
    if Encounters.session_authorized?(Exam.context().db,s.assigns.session,s.assigns.enc,s.assigns.actor,:clinician,:read) do
      Process.send_after(self(),:refresh,1000)
      {:noreply,assign(s,:rows,AcquisitionWorkflow.list(Exam.context(),s.assigns.enc,s.assigns.actor))}
    else {:noreply,redirect(s,to: "/")} end
  end
  def handle_event(event,params,s) do
    if Encounters.session_authorized?(Exam.context().db,s.assigns.session,s.assigns.enc,s.assigns.actor,:clinician,:read),
      do: event(event,params,s),else: {:noreply,redirect(s,to: "/")}
  end
  defp event("grant",p,s) do
    result=DeviceSessions.authorize(Exam.context().db,s.assigns.enc,p["device"],p["profile"],p["site"],s.assigns.actor)
    {:noreply,assign(s,:message,if(match?({:ok,_},result),do: "Authorized",else: "Authorization refused"))}
  end
  defp event("band",%{"id"=>id,"sample"=>sample},s) do
    result=with {:ok,index} <- MedFabric.Domain.Review.counter(sample),
                row when not is_nil(row) <- Enum.find(s.assigns.rows,&(&1.id == id)),
                true <- is_map(row.manifest) and row.profile == "paired_exam",
                {:ok,manifest} <- MedFabric.Exam.AcquisitionManifest.promoted(Exam.context(),s.assigns.enc,id,s.assigns.actor,row.digest) do
      AcquisitionWorkflow.band(manifest,index)
    else _ -> :unavailable end
    {:noreply,assign(s,:bands,Map.put(s.assigns.bands,id,result))}
  end
  defp event("deliver",%{"id"=>id},s) do
    result=Exam.deliver(s.assigns.enc,id,s.assigns.actor)
    {:noreply,assign(s,:message,if(match?({:ok,_},result),do: "Delivery requested",else: "Delivery refused"))}
  end
  defp event("stop",%{"id"=>id},s) do
    result=AcquisitionWorkflow.stop(Exam.context(),s.assigns.enc,id,s.assigns.actor)
    {:noreply,assign(s,:message,if(match?({:ok,_},result),do: "Stop requested",else: "Stop refused"))}
  end
  defp event("gain",%{"id"=>id,"gain"=>gain},s) do
    result=MedFabric.Store.DeviceCommands.request(Exam.context().db,s.assigns.enc,id,s.assigns.actor,gain)
    {:noreply,assign(s,:message,if(match?({:ok,_},result),do: "Monitor command requested",else: "Command refused"))}
  end
  defp event(_,_,s),do: {:noreply,s}
  defp metric_text(["value",m,e,unit]),do: m<>" × 10^"<>e<>" "<>unit
  defp metric_text(["missing",reason]),do: "Unavailable: "<>reason
  defp metric_text(value),do: Jason.encode!(value)
  defp provenance_text(facts) do
    facts |> Enum.filter(&(&1["name"] in ~w(source simulated phase time_basis peripheral_redelivery repeat_of)))
    |> Enum.map_join("; ",fn fact -> fact["name"]<>" ("<>fact["origin"]<>"): "<>Jason.encode!(fact["value"]) end)
  end
  defp band_text(:unavailable),do: "Clock alignment unavailable; no correspondence inferred"
  defp band_text(ranges) when is_list(ranges),do: "Possible ECG ranges: "<>Enum.map_join(ranges,", ",fn {a,b}->"#{a}–#{b}" end)
  def render(assigns) do
    ~H"""
    <main><h1>Acquisitions</h1><a href={"/encounters/#{@enc}"}>Encounter</a><p>{@message}</p>
      <form phx-submit="grant"><select name="device"><option :for={device <- @devices} value={device}>{device}</option></select>
        <select name="profile"><option value="paired_exam">Paired audio / ECG</option><option value="plx_spot_check">PLX spot check</option></select>
        <input name="site" placeholder="Site" required /><button>Authorize device</button>
      </form>
      <article :for={row <- @rows} id={"acquisition-#{row.id}"} data-acquisition={row.id} data-digest={row.digest} data-state={row.phase}>
        <h2>{row.profile}</h2><p>{row.site} · {row.phase}</p>
        <button :if={row.phase == "capturing"} phx-click="stop" phx-value-id={row.id}>Request source stop</button>
        <div :if={row.live} id={"live-ecg-#{row.id}"}>
          <p>Live synthetic ECG · {row.live.unit} · samples {row.live.first}–{row.live.end_sample}; display only</p>
          <svg viewBox="0 0 800 125" role="img" aria-label="Live ECG"><polyline points={row.live.points} fill="none" stroke="currentColor" /></svg>
        </div>
        <form :if={row.profile == "paired_exam" && row.phase == "capturing"} phx-submit="gain">
          <input type="hidden" name="id" value={row.id} /><label>Monitor gain <select name="gain"><option value="unity">Unity</option><option value="half">Half</option></select></label><button>Request monitor gain</button>
        </form>
        <section :if={row.phase == "capturing"} id={"monitor-#{row.id}"} phx-hook="DeviceMonitor" phx-update="ignore" data-endpoint={"/encounters/#{@enc}/acquisitions/#{row.id}/preview"} data-encounter={@enc}>
          <button type="button">Monitor audio</button><audio autoplay controls></audio><output></output>
        </section>
        <p :if={row.manifest && row.manifest["defects"] != []}>Evidence contains explicit defects: {Enum.map_join(row.manifest["defects"],", ",& &1["code"])}</p>
        <div :if={row.manifest}>
          <section :if={row.profile == "plx_spot_check"}>
            <h3>Preserved spot-check events</h3>
            <p>Simulated PLXS source. Clinical acceptance checks exact values, device status and qualified source time. Unusable and unknown values remain visible.</p>
            <details :for={entry <- row.manifest["inventory"]} data-event={entry["event"]["event_id"]}>
              <summary>Event {entry["event"]["event_id"]} · gateway sequence {entry["event"]["gateway_sequence"]}</summary>
              <p :for={{code,value} <- Enum.sort(entry["event"]["metrics"])}>{code}: {metric_text(value)}</p>
              <p>Source status: {Jason.encode!(entry["event"]["device_status"])}</p>
              <p>Source time: {Jason.encode!(entry["event"]["device_time"])}</p>
              <p>Provenance: {provenance_text(entry["event"]["provenance"])}</p>
            </details>
            <p :if={row.manifest["inventory"] == []}>No measurements were committed.</p>
          </section>
          <div :for={{name,stream} <- row.manifest["streams"]}>
            <h3>{name}</h3>
            <div :for={segment <- Enum.sort_by(stream["index"]["segments"], &String.to_integer(&1["first_sample"]))}>
              <audio :if={name == "audio"} controls preload="none" data-first-sample={segment["first_sample"]} src={"/encounters/#{@enc}/acquisitions/#{row.id}/segment/#{name}/#{segment["first_sample"]}/#{segment["sha256"]}?revision=#{row.digest}"}></audio>
              <img :if={name == "ecg"} alt="Verified synthetic ECG segment" src={"/encounters/#{@enc}/acquisitions/#{row.id}/segment/#{name}/#{segment["first_sample"]}/#{segment["sha256"]}?revision=#{row.digest}"} />
              <a href={"/encounters/#{@enc}/acquisitions/#{row.id}/segment/#{name}/#{segment["first_sample"]}/#{segment["sha256"]}?revision=#{row.digest}"}>Verified segment {segment["first_sample"]}–{segment["end_sample"]}</a>
            </div>
            <p>Clock mapping: {stream["clock"]["state"]}. Source uncertainty remains part of the evidence.</p>
            <p :for={span <- stream["index"]["spans"]}>{span["code"]}: samples {span["first_sample"]}–{span["end_sample"]}</p>
          </div>
          <form :if={row.profile == "paired_exam"} phx-submit="band">
            <input type="hidden" name="id" value={row.id} /><label>Audio sample <input name="sample" inputmode="numeric" required /></label><button>Find corresponding ECG ranges</button>
          </form>
          <output :if={Map.has_key?(@bands,row.id)}>{band_text(@bands[row.id])}</output>
          <form :if={!row.choice} id={"review-#{row.id}"} phx-hook="AcquisitionReview" phx-update="ignore" data-endpoint={"/encounters/#{@enc}/acquisitions/#{row.id}/action"} data-digest={row.digest} data-defects={Jason.encode!(row.manifest["defects"])}>
            <select name="decision"><option value="complete">Complete waveform review</option><option value="partial">Partial waveform review</option><option value="accept_metrics">Accept selected metrics</option><option value="reject">Reject</option><option value="repeat">Repeat</option></select>
            <input name="range" placeholder="audio:first:end" /><input name="event_id" placeholder="Event ID" />
            <label><input type="checkbox" name="spo2" />SpO₂</label><label><input type="checkbox" name="pulse_rate" />Pulse</label>
            <label><input type="checkbox" name="acknowledged" />Acknowledge defects</label><textarea name="note"></textarea><button>Save clinical decision</button><output></output>
          </form>
          <p :if={row.choice}>Clinical decision: {row.choice["decision"]}</p>
          <div :for={[id,kind,status] <- row.metrics} data-observation={id} data-delivery={status}>
            <p>{kind}: export {status}</p><button :if={status != "confirmed"} phx-click="deliver" phx-value-id={id}>Request delivery</button>
          </div>
        </div>
      </article>
    </main>
    """
  end
end
