defmodule MedFabric.ExamWeb.DeviceLive do
  use Phoenix.LiveView
  alias MedFabric.Exam
  alias MedFabric.Exam.{DeviceReviews, DeviceWorkflow}
  alias MedFabric.ExamWeb.ProxyIdentity
  alias MedFabric.Store.{DeviceCommands, DeviceSessions, Postgres}

  def mount(
        %{"encounter_id" => enc},
        %{"lab_encounter" => enc, "exam_actor" => actor, "exam_role" => "clinician"},
        socket
      ) do
    ok =
      not connected?(socket) or
        ProxyIdentity.matches?(
          get_connect_info(socket, :x_headers) || [],
          actor,
          Exam.lab()
        )

    if ok and Exam.lab()[:device_enabled] == true and Exam.member?(enc, actor, :clinician) do
      if connected?(socket), do: Process.send_after(self(), :refresh, 1000)

      devices =
        DeviceSessions.rows(
          Postgres,
          "SELECT device_id FROM device_credentials WHERE NOT revoked ORDER BY device_id",
          []
        )
        |> List.flatten()

      {:ok,
       assign(socket,
         enc: enc,
         actor: actor,
         devices: devices,
         rows: DeviceWorkflow.list(enc),
         message: nil,
         band: nil
       )}
    else
      {:ok, redirect(socket, to: "/")}
    end
  end

  def mount(_, _, socket), do: {:ok, redirect(socket, to: "/")}

  def handle_info(:refresh, s) do
    if Exam.member?(s.assigns.enc, s.assigns.actor, :clinician) do
      Process.send_after(self(), :refresh, 1000)
      {:noreply, assign(s, :rows, DeviceWorkflow.list(s.assigns.enc))}
    else
      {:noreply, redirect(s, to: "/")}
    end
  end

  def handle_event("grant", p, s),
    do:
      result(
        s,
        DeviceSessions.authorize(
          s.assigns.enc,
          p["device"],
          p["profile"],
          p["site"],
          s.assigns.actor
        )
      )

  def handle_event("stop", %{"id" => id}, s),
    do: result(s, DeviceWorkflow.stop(s.assigns.enc, id, s.assigns.actor))

  def handle_event("gain", p, s),
    do: result(s, DeviceCommands.request(s.assigns.enc, p["_id"], s.assigns.actor, p["gain"]))

  def handle_event("deliver", %{"id" => id}, s),
    do: result(s, Exam.deliver(s.assigns.enc, id, s.assigns.actor))

  def handle_event("band", p, s) do
    row = Enum.find(s.assigns.rows, &(&1.id == p["_id"] and &1.digest == p["digest"]))

    band =
      with %{manifest: %{} = m} <- row,
           {i, ""} <- Integer.parse(p["sample"]),
           do: DeviceWorkflow.band(m, i)

    {:noreply, assign(s, :band, {p["_id"], band})}
  end

  def handle_event("review", p, s) do
    m =
      Enum.find_value(s.assigns.rows, fn r ->
        if r.id == p["_id"] and r.digest == p["digest"], do: r.manifest
      end)

    if m do
      choice = %{
        "decision" => p["decision"],
        "note" => p["note"] || "",
        "metrics" => Enum.sort(p["metrics"] || []),
        "event_id" => p["event_id"],
        "acknowledged" => if(p["ack"] == "yes", do: m["defects"], else: []),
        "ranges" => review_ranges(p["range"])
      }

      result(
        s,
        DeviceReviews.review_verified(
          s.assigns.enc,
          p["_id"],
          s.assigns.actor,
          p["digest"],
          choice
        )
      )
    else
      result(s, {:error, :review_changed})
    end
  end

  defp review_ranges(range) when range in [nil, ""], do: []

  defp review_ranges(range) do
    case String.split(range, ":") do
      [stream, first, last] -> [%{"stream" => stream, "first" => first, "end" => last}]
      _ -> []
    end
  end

  defp result(s, r),
    do:
      {:noreply,
       assign(s,
         message: if(r in [:ok, {:ok, :ok}], do: "Saved", else: "Action refused: " <> inspect(r)),
         rows: DeviceWorkflow.list(s.assigns.enc)
       )}

  defp metric(%{"mantissa" => m, "exponent" => e}, unit) do
    n = String.to_integer(m)
    value = Decimal.new(if(n < 0, do: -1, else: 1), abs(n), String.to_integer(e))
    Decimal.to_string(value, :normal) <> " " <> unit
  end

  defp metric(%{"missing" => reason}, _), do: "Unavailable (" <> reason <> ")"

  defp segment_path(enc, row, stream, segment),
    do:
      "/encounters/#{enc}/devices/#{row.id}/segment/#{stream}/#{segment["first_sample"]}/#{segment["sha256"]}?revision=#{row.digest}"

  def render(assigns) do
    ~H"""
    <main>
      <header class="mf-topbar">
        <a href={"/encounters/#{@enc}"}>&larr; Encounter</a>
        <span class="mf-brand">Med Fabric · Handheld Review</span>
      </header>
      <h1>Simulated handheld examinations</h1>
      <form class="mf-panel" phx-submit="grant">
        <label>Assigned device <select name="device"><option :for={d <- @devices}>{d}</option></select></label>
        <label>Protocol <select name="profile"><option value="paired_exam">Paired acoustic and ECG</option><option value="plx_spot_check">Pulse oximeter spot check</option></select></label>
        <label>Recording site <input required maxlength="100" name="site" /></label>
        <button>Confirm readiness and authorize collection</button>
      </form>
      <p role="status">{@message}</p>
      <section :for={r <- @rows} id={"device-"<>r.id}>
        <h2>{r.profile} · {r.site}</h2>
        <p class="mf-meta">Gateway {r.device} · capture {r.phase}</p>
        <p class="mf-meta" :for={{name,spec}<-r.descriptors}>{name} · {spec["modality"]} · {spec["encoding"]} · {Enum.join(spec["sample_rate"], "/")} samples/s · {spec["boot_id"]}</p>
        <figure :if={r.live}>
          <svg viewBox="0 0 800 125" role="img" aria-label="Latest received ECG frame"><polyline points={r.live.points} fill="none" stroke="currentColor" stroke-width="1.5"/></svg>
          <figcaption>Latest received ECG · samples {r.live.first}–{r.live.end_sample} · {r.live.low}–{r.live.high} {r.live.unit}. Network transit time unknown.</figcaption>
        </figure>
        <p class="mf-meta" :for={[kind,fact] <- r.facts}>{kind} · {JSON.encode!(fact)}</p>
        <div class="mf-controls" :if={r.phase=="capturing"}>
          <button phx-click="stop" phx-value-id={r.id}>Request stop</button>
          <form :if={r.profile=="paired_exam"} phx-submit="gain">
            <input type="hidden" name="_id" value={r.id} />
            <label>Handheld software monitor <select name="gain"><option>unity</option><option>half</option></select></label>
            <button>Apply gain</button>
          </form>
          <div :if={r.profile=="paired_exam"} id={"listen-"<>r.id} phx-hook="DeviceMonitor" phx-update="ignore" data-endpoint={"/encounters/#{@enc}/devices/#{r.id}/preview"}>
            <button type="button">Listen to monitor</button><audio controls autoplay></audio><output>Disconnected</output>
          </div>
        </div>
        <article :if={r.manifest}>
          <p>Manifest <code>{r.digest}</code></p>
          <p class="mf-meta">Integrity {if r.manifest["defects"] == [], do: "complete", else: JSON.encode!(r.manifest["defects"])}</p>
          <div class="mf-stream" :for={{name,v} <- r.manifest["streams"]}>
            <h3>{name} · {v["index"]["stream"]["encoding"]}</h3>
            <p class="mf-meta">Alignment {v["clock"]["state"]}</p>
            <p :if={v["index"]["terminal"] == "interrupted"}>
              Capture interrupted · {v["index"]["terminal_reason"]}
            </p>
            <p :for={gap <- Enum.filter(v["index"]["spans"], &(&1["code"] == "source_gap"))}>
              Source gap · samples {gap["first_sample"]}–{gap["end_sample"]}
            </p>
            <audio :if={name == "audio" && match?([_, "1"], v["index"]["stream"]["sample_rate"]) && v["index"]["segments"] != []}
              aria-label="First verified acoustic segment" controls preload="none"
              src={segment_path(@enc, r, name, hd(v["index"]["segments"]))}></audio>
            <details><summary>Verified source intervals</summary>
              <div :for={seg <- v["index"]["segments"]}>
                <a href={segment_path(@enc, r, name, seg)}>{seg["first_sample"]}–{seg["end_sample"]} · inspect segment</a>
              </div>
            </details>
          </div>
          <form :if={r.profile=="paired_exam"} phx-submit="band"><input type="hidden" name="_id" value={r.id}/><input type="hidden" name="digest" value={r.digest}/><label>Audio sample <input name="sample" type="number" min="0" required/></label><button>Find corresponding ECG ranges</button></form>
          <p :if={@band && elem(@band,0)==r.id}>Possible ECG ranges {inspect(elem(@band,1))}</p>
          <div class="mf-stream" :for={x <- r.manifest["inventory"]}>
            <p>{x["event"]["event_id"]} · Source {x["event"]["source"]} · SpO₂ {metric(x["event"]["metrics"]["spo2"],"%")} · device pulse {metric(x["event"]["metrics"]["pulse_rate"],"beats/min")} · source status {JSON.encode!(x["event"]["source_status"])}</p>
            <p class="mf-meta">Measured {x["event"]["measured_at"] || "unknown"} ({x["event"]["time_basis"]}) · received {x["received_at"]} · repeat of {x["event"]["repeat_of"] || "none"}</p>
          </div>
          <form :if={!r.choice} phx-submit="review">
            <input type="hidden" name="_id" value={r.id}/><input type="hidden" name="digest" value={r.digest}/>
            <label>Decision <select name="decision"><option :for={v <- (if r.profile=="paired_exam", do: ~w(complete partial reject repeat), else: ~w(accept_metrics reject repeat))}>{if v == "complete", do: "Accept interval from complete capture", else: v}</option></select></label>
            <label :if={r.profile=="paired_exam"}>Selected interval (stream:first:end, within one configuration epoch and without gaps)<input name="range"/></label>
            <label :if={r.manifest["defects"] != []}><input type="checkbox" name="ack" value="yes"/>Acknowledge the listed defects</label>
            <div :if={r.profile=="plx_spot_check"}><label>Completed event <select name="event_id"><option :for={x<-r.manifest["inventory"]}>{x["event"]["event_id"]}</option></select></label>
              <label :for={m<- ~w(spo2 pulse_rate)}><input type="checkbox" name="metrics[]" value={m}/>{m}</label></div>
            <label>Review note <input name="note" maxlength="2000"/></label><button>Record review</button>
          </form>
          <p :if={r.choice}>Review decision {r.choice["decision"]} · {r.choice["note"]}</p>
          <p :for={[id,kind,remote]<-r.metrics}>{kind} · {remote || "pending export"} <button :if={!remote} phx-click="deliver" phx-value-id={id}>Deliver to FHIR</button></p>
        </article>
      </section>
    </main>
    """
  end
end
