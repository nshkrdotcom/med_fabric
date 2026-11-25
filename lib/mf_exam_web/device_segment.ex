defmodule MedFabric.ExamWeb.DeviceSegment do
  @moduledoc false
  import Plug.Conn
  alias MedFabric.Exam.DeviceWorkflow
  def init(p), do: p

  def call(c, _) do
    p = c.path_params

    with "clinician" <- get_session(c, :exam_role),
         {:ok, spec, seg, raw} <-
           DeviceWorkflow.segment(
             p["encounter_id"],
             p["id"],
             c.query_params["revision"],
             p["stream"],
             p["sha"]
           ) do
      respond(put_resp_header(c, "cache-control", "no-store"), spec, seg, raw)
    else
      _ -> send_resp(c, 404, "Segment unavailable")
    end
  end

  defp respond(c, %{stream_id: "audio", sample_rate: {rate, 1}} = s, _, raw) do
    width = MedEx.StreamSpec.bytes_per_value(s.encoding)
    channels = length(s.channels)
    size = byte_size(raw)

    wav =
      <<"RIFF", 36 + size::little-32, "WAVEfmt ", 16::little-32, 1::little-16,
        channels::little-16, rate::little-32, rate * channels * width::little-32,
        channels * width::little-16, width * 8::little-16, "data", size::little-32, raw::binary>>

    c |> put_resp_content_type("audio/wav") |> send_resp(200, wav)
  end

  defp respond(c, s, seg, raw) do
    t = DeviceWorkflow.trace(s, seg.first_sample, raw)
    label = Plug.HTML.html_escape("#{s.stream_id}, #{t.label}: #{t.low} to #{t.high} #{t.unit}")

    c
    |> put_resp_content_type("image/svg+xml")
    |> send_resp(
      200,
      "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 800 155'><title>Verified synthetic source segment</title><polyline points='#{t.points}' fill='none' stroke='black'/><text x='4' y='148'>#{label}; samples #{seg.first_sample}–#{seg.end_sample}, every #{t.step} rows</text></svg>"
    )
  end
end
