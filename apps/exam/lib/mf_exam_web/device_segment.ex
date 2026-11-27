defmodule MedFabric.ExamWeb.DeviceSegment do
  @moduledoc false
  import Plug.Conn
  alias MedFabric.Exam.AcquisitionWorkflow
  def init(p), do: p

  def call(c, _) do
    p = c.path_params

    with "clinician" <- get_session(c, :exam_role),
         {:ok, spec, seg, raw} <-
           AcquisitionWorkflow.segment(
             MedFabric.Exam.context(),
             p["encounter_id"],
             p["id"],
             get_session(c, :exam_actor),
             c.query_params["revision"],
             p["stream"],
             p["first_sample"],
             p["sha"]
           ) do
      respond(put_resp_header(c, "cache-control", "no-store"), spec, seg, raw)
    else
      _ -> send_resp(c, 404, "Segment unavailable")
    end
  end

  defp respond(c, %{stream_id: "audio", sample_rate: {rate, 1}} = s, _, raw) do
    case MedEx.Format.Wav.header(s.encoding, length(s.channels), rate, byte_size(raw)) do
      {:ok, header} -> c |> put_resp_content_type("audio/wav") |> send_resp(200, header <> raw)
      _ -> send_resp(c, 415, "Unsupported playback projection")
    end
  end

  defp respond(c, s, seg, raw) do
    t = AcquisitionWorkflow.trace(s, seg.first_sample, raw)
    label = Plug.HTML.html_escape("#{s.stream_id}, #{t.label}: #{t.low} to #{t.high} #{t.unit}")

    c
    |> put_resp_content_type("image/svg+xml")
    |> send_resp(
      200,
      "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 800 155'><title>Verified synthetic source segment</title><polyline points='#{t.points}' fill='none' stroke='black'/><text x='4' y='148'>#{label}; samples #{seg.first_sample}–#{seg.end_sample}, every #{t.step} rows</text></svg>"
    )
  end
end
