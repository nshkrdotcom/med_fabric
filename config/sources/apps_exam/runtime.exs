import Config
path = "/etc/med_fabric/exam.json"

settings =
  if config_env() != :test and File.regular?(path) do
    case path |> File.read!() |> Elixir.JSON.decode!() do
      %{} = settings -> settings
      _ -> raise "Exam deployment configuration must be a JSON object"
    end
  end

if settings != nil or System.get_env("MF_LAB") == "1" do
  get = fn key, env, default ->
    if settings do
      Map.get(settings, key, default)
    else
      System.get_env(env, default)
    end
  end

  required = fn key, env ->
    if settings do
      Map.fetch!(settings, key)
    else
      System.fetch_env!(env)
    end
  end

  secret = fn key, env ->
    if settings do
      case settings[key <> "_file"] do
        nil ->
          nil

        file ->
          value = file |> File.read!() |> String.trim()

          if value == "" do
            raise "Empty #{key} credential"
          end

          value
      end
    else
      System.get_env(env)
    end
  end

  encounters =
    required.("encounters_file", "MF_ENCOUNTERS_FILE") |> File.read!() |> Elixir.JSON.decode!()

  entries =
    for entry <- encounters, into: %{} do
      %{
        "exam" => id,
        "patient_actor" => patient,
        "clinician_actor" => clinician,
        "patient_ref" => patient_ref,
        "encounter_ref" => encounter_ref,
        "destination" => destination
      } = entry

      unless Regex.match?(~r/\A[a-zA-Z0-9-]{1,48}\z/, id) and
               Enum.all?([patient, clinician, destination], &(is_binary(&1) and &1 != "")) and
               patient != clinician and
               Regex.match?(~r/\APatient\/[A-Za-z0-9.\-]{1,64}\z/, patient_ref) and
               Regex.match?(~r/\AEncounter\/[A-Za-z0-9.\-]{1,64}\z/, encounter_ref) do
        raise "Invalid encounter configuration for #{inspect(id)}"
      end

      {id, entry}
    end

  unless is_list(encounters) and encounters != [] and map_size(entries) == length(encounters) do
    raise "encounters file must contain a nonempty array with unique exam IDs"
  end

  port = to_string(get.("http_port", "MF_HTTP_PORT", "4000")) |> String.to_integer()

  unless port in 1..65535 do
    raise "Invalid Exam HTTP port"
  end

  origin = get.("public_origin", "MF_PUBLIC_ORIGIN", "http://localhost:#{port}")
  uri = URI.new!(origin)
  local? = uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1"] and uri.port == port

  unless (uri.host && (local? or uri.scheme == "https")) and uri.path in [nil, "", "/"] and
           is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
    raise "public origin must be a localhost HTTP origin or a public HTTPS origin"
  end

  proxy_secret = secret.("proxy_secret", "MF_PROXY_SECRET")

  if local? do
    keys = Enum.flat_map(encounters, &[&1["patient_key"], &1["clinician_key"]])

    unless Enum.all?(keys, &(is_binary(&1) and byte_size(&1) >= 32)) and
             length(Enum.uniq(keys)) == length(keys) do
      raise "Local encounter access keys must be unique and at least 32 bytes long"
    end
  else
    unless is_binary(proxy_secret) and byte_size(proxy_secret) >= 32 do
      raise "HTTPS operation requires a proxy secret and an authenticating loopback reverse proxy"
    end
  end

  urls =
    get.("turn_urls", "MF_TURN_URLS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  unless Enum.all?(urls, &Regex.match?(~r/\Aturns?:[^\s,]+\z/, &1)) do
    raise "MF_TURN_URLS must contain turn: or turns: URLs"
  end

  turn_secret = secret.("turn_secret", "MF_TURN_SECRET")
  relay? = get.("relay_only", "MF_RELAY_ONLY", nil) in [true, "1"]

  if (relay? or urls != []) and
       (urls == [] or !is_binary(turn_secret) or byte_size(turn_secret) < 32) do
    raise "TURN requires URLs and a secret of at least 32 bytes"
  end

  cert = get.("device_tls_certfile", "MF_DEVICE_TLS_CERTFILE", nil)
  key = get.("device_tls_keyfile", "MF_DEVICE_TLS_KEYFILE", nil)

  if is_nil(cert) != is_nil(key) do
    raise "Configure both device TLS certificate and key"
  end

  if cert do
    {:ok, bind_ip} =
      :inet.parse_address(
        String.to_charlist(get.("device_bind_ip", "MF_DEVICE_BIND_IP", "127.0.0.1"))
      )

    tls_port =
      to_string(get.("device_tls_port", "MF_DEVICE_TLS_PORT", "4443")) |> String.to_integer()

    unless tls_port in 1..65535 do
      raise "Invalid Exam device TLS port"
    end

    config :mf_exam, MedFabric.ExamWeb.Endpoint,
      https: [ip: bind_ip, port: tls_port, certfile: cert, keyfile: key]
  end

  if sidecar = get.("preview_url", "MF_PREVIEW_URL", nil) do
    uri = URI.new!(sidecar)

    unless uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost"] do
      raise "Preview feed must use a same-host listener"
    end

    preview_secret =
      required.("preview_credential_file", "MF_PREVIEW_CREDENTIAL_FILE")
      |> File.read!()
      |> String.trim()

    if preview_secret == "" do
      raise "Empty Preview credential"
    end

    config :mf_exam, :sidecar, %{url: sidecar, secret: preview_secret}
  end

  config :mf_exam, :lab, %{
    device_enabled: not is_nil(cert),
    encounters: entries,
    local?: local?,
    proxy_secret:
      if local? do
        nil
      else
        proxy_secret
      end,
    turn: %{urls: urls, secret: turn_secret, relay?: relay?},
    database_url:
      secret.("database_url", "DATABASE_URL") || raise("Missing database_url credential"),
    artifact_dir: Path.expand(required.("artifact_dir", "MF_ARTIFACT_DIR"))
  }

  config :mf_exam, MedFabric.ExamWeb.Endpoint,
    adapter: Bandit.PhoenixAdapter,
    render_errors: [formats: [html: MedFabric.ExamWeb.ErrorHTML], layout: false],
    pubsub_server: MedFabric.Exam.PubSub,
    live_view: [signing_salt: "med_fabric_exam_lv_salt"],
    server: true,
    check_origin:
      (if local? do
         ["//localhost:#{port}", "//127.0.0.1:#{port}"]
       else
         [origin]
       end),
    url: [scheme: uri.scheme, host: uri.host, port: uri.port],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base:
      secret.("secret_key_base", "MF_SECRET_KEY_BASE") ||
        raise("Missing secret_key_base credential")
end

if is_nil(settings) and System.get_env("MF_EXAM_LEGACY_MEDIA") == "1" do
  config :med_ex, :rtc_provider, MedEx.RTC.Provider
  config :med_ex, :preview_provider, MedEx.Opus.Provider
end
