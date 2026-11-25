# mix run --no-start --no-halt ../../ops/run_exam.exs --config /absolute/server.json
{opts, _, []} =
  OptionParser.parse(Enum.reject(System.argv(), &(&1 == "--")), strict: [config: :string])

c = File.read!(Keyword.fetch!(opts, :config)) |> JSON.decode!()
entries = Map.new(c["encounters"], &{&1["exam"], &1})

Application.put_env(:mf_exam, :lab, %{
  device_enabled: true,
  encounters: entries,
  local?: true,
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

{:ok, _} = Application.ensure_all_started(:mf_exam)
alias MedFabric.Store.DeviceSessions

for d <- c["devices"] do
  true = DeviceSessions.enroll(d["id"], File.read!(d["credential_file"]) |> String.trim())

  if c["authorize_scenarios"] do
    for p <- ~w(paired_exam plx_spot_check) do
      e = Map.fetch!(entries, d["exam"])

      :ok =
        DeviceSessions.authorize(
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
