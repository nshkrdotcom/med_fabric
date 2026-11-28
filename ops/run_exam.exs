defmodule MedFabric.ExamLabTimings do
  @moduledoc false

  def append([:mf_exam, :acquisition_ingress, :bounds] = event, measurements, metadata, path) do
    # Each socket reports monotone high-water marks for its connection.
    if Process.put({__MODULE__, :bounds, metadata.stream}, measurements) != measurements do
      write(event, measurements, metadata, path)
    end
  end

  def append(event, measurements, metadata, path), do: write(event, measurements, metadata, path)

  defp write(event, measurements, metadata, path) do
    sample = %{
      at_ms: System.system_time(:millisecond),
      stream: metadata[:stream],
      stage: metadata[:stage] || List.last(event),
      duration_us: measurements[:duration_us],
      measurements:
        Map.take(measurements, [
          :max_frame_bytes,
          :max_payload_bytes,
          :max_pending_bytes,
          :max_pending_frames
        ])
    }

    File.write!(path, [JSON.encode_to_iodata!(sample), "\n"], [:append])
  end
end

# mix run --no-start --no-halt ../../ops/run_exam.exs --config /absolute/server.json
{opts, _, []} =
  OptionParser.parse(Enum.reject(System.argv(), &(&1 == "--")), strict: [config: :string])

c = File.read!(Keyword.fetch!(opts, :config)) |> JSON.decode!()
entries = Map.new(c["encounters"], &{&1["exam"], &1})

Application.put_env(:mf_exam, :lab, %{
  deployment_uuid: Map.fetch!(c, "deployment_uuid"),
  device_enabled: true,
  encounters: entries,
  local?: true,
  public_origin: "http://localhost:#{c["http_port"]}",
  turn: %{urls: [], secret: nil, relay?: false},
  proxy_secret: nil,
  database_url: c["database_url"],
  artifact_dir: c["artifact_dir"]
})

Application.put_env(:mf_exam, :barriers, c["barrier_dir"])

if c["preview_url"] do
  Application.put_env(:mf_exam, :sidecar, %{
    url: c["preview_url"],
    secret: File.read!(c["preview_credential_file"]) |> String.trim()
  })
end

opts = Application.get_env(:mf_exam, MedFabric.ExamWeb.Endpoint, [])

Application.put_env(
  :mf_exam,
  MedFabric.ExamWeb.Endpoint,
  Keyword.merge(opts,
    server: true,
    url: [host: "localhost", scheme: "http", port: c["http_port"]],
    http: [port: c["http_port"], ip: {127, 0, 0, 1}],
    https: [port: c["tls_port"], ip: {127, 0, 0, 1}, certfile: c["cert"], keyfile: c["key"]],
    check_origin: ["//localhost:#{c["http_port"]}", "//127.0.0.1:#{c["http_port"]}"],
    secret_key_base: c["cookie_secret"]
  )
)

if path = c["checkpoint_timings"] do
  {:ok, _} = Application.ensure_all_started(:telemetry)
  File.write!(path, "", [:append])

  :ok =
    :telemetry.attach_many(
      {__MODULE__, path},
      [
        [:mf_exam, :acquisition_ingress, :checkpoint],
        [:mf_exam, :acquisition_ingress, :writer_checkpoint],
        [:mf_exam, :acquisition_ingress, :frame_scope],
        [:mf_exam, :acquisition_ingress, :commit_return],
        [:mf_exam, :acquisition_ingress, :request_timing],
        [:mf_exam, :acquisition_ingress, :bounds]
      ],
      &MedFabric.ExamLabTimings.append/4,
      path
    )
end

{:ok, _} = Application.ensure_all_started(:mf_exam)
alias MedFabric.Store.DeviceSessions
db = MedFabric.Exam.context().db

for d <- c["devices"] do
  true = DeviceSessions.enroll(db, d["id"], File.read!(d["credential_file"]) |> String.trim())

  if c["authorize_scenarios"] do
    for p <- ~w(paired_exam plx_spot_check) do
      e = Map.fetch!(entries, d["exam"])

      {:ok, :ok} =
        DeviceSessions.authorize(
          db,
          e["exam"],
          d["id"],
          p,
          "Synthetic anterior site",
          e["clinician_actor"]
        )
    end
  end
end

IO.puts("Synthetic exam ready")
