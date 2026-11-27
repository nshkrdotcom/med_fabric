import Config

if config_env() != :test, do: config(:logger, level: :info)

path = "/etc/med_fabric/exam.json"

# Runtime configuration is evaluated before the host Logger filter is installed.
# Refuse malformed input with fixed categories rather than exception arguments,
# map contents, credential paths or JSON fragments.
read_file = fn path, message ->
  case is_binary(path) && File.read(path) do
    {:ok, bytes} -> bytes
    _ -> raise message
  end
end

read_json = fn path, message ->
  case path |> read_file.(message) |> Elixir.JSON.decode() do
    {:ok, value} -> value
    _ -> raise message
  end
end

parse_port = fn value, message ->
  parsed =
    cond do
      is_integer(value) -> value
      is_binary(value) -> Integer.parse(value)
      true -> nil
    end

  case parsed do
    number when is_integer(number) and number in 1..65535 -> number
    {number, ""} when number in 1..65535 -> number
    _ -> raise message
  end
end

parse_uri = fn value, message ->
  case is_binary(value) && URI.new(value) do
    {:ok, uri} -> uri
    _ -> raise message
  end
end

settings =
  if config_env() != :test and File.regular?(path) do
    case read_json.(path, "Invalid Exam deployment configuration") do
      %{} = settings -> settings
      _ -> raise "Exam deployment configuration must be a JSON object"
    end
  end

if settings != nil or System.get_env("MF_LAB") == "1" do
  get = fn key, env, default ->
    if settings, do: Map.get(settings, key, default), else: System.get_env(env, default)
  end

  required = fn key, env ->
    value = if settings, do: Map.get(settings, key), else: System.get_env(env)

    if is_binary(value) and value != "",
      do: value,
      else: raise("Missing Exam deployment setting")
  end

  secret = fn key, env ->
    if settings do
      case settings[key <> "_file"] do
        nil ->
          nil

        file ->
          value = file |> read_file.("Unreadable Exam credential") |> String.trim()
          if value == "", do: raise("Empty #{key} credential")
          value
      end
    else
      System.get_env(env)
    end
  end

  encounters =
    required.("encounters_file", "MF_ENCOUNTERS_FILE")
    |> read_json.("Invalid encounter configuration")

  unless is_list(encounters) and encounters != [], do: raise("Invalid encounter configuration")

  entries =
    for entry <- encounters, into: %{} do
      {id, patient, clinician} =
        case entry do
          %{"exam" => id, "patient_actor" => patient, "clinician_actor" => clinician} ->
            {id, patient, clinician}

          _ ->
            raise "Invalid encounter configuration"
        end

      unless is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9-]{1,48}\z/, id) and
               Enum.all?([patient, clinician], &(is_binary(&1) and &1 != "")) and
               patient != clinician do
        raise "Invalid encounter configuration"
      end

      {id, entry}
    end

  unless map_size(entries) == length(encounters),
    do: raise("encounters file must contain a nonempty array with unique exam IDs")

  port = parse_port.(get.("http_port", "MF_HTTP_PORT", "4000"), "Invalid Exam HTTP port")
  origin = get.("public_origin", "MF_PUBLIC_ORIGIN", "http://localhost:#{port}")
  uri = parse_uri.(origin, "Invalid Exam public origin")
  local? = uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1"] and uri.port == port

  unless is_binary(uri.host) and (local? or uri.scheme == "https") and
           uri.path in [nil, "", "/"] and is_nil(uri.userinfo) and is_nil(uri.query) and
           is_nil(uri.fragment),
         do: raise("Invalid Exam public origin")

  public_uri = uri

  proxy_secret = secret.("proxy_secret", "MF_PROXY_SECRET")

  if local? do
    keys = Enum.flat_map(encounters, &[&1["patient_key"], &1["clinician_key"]])

    unless Enum.all?(keys, &(is_binary(&1) and byte_size(&1) >= 32)) and
             length(Enum.uniq(keys)) == length(keys),
           do: raise("Local encounter access keys must be unique and at least 32 bytes long")
  else
    unless is_binary(proxy_secret) and byte_size(proxy_secret) >= 32,
      do:
        raise(
          "HTTPS operation requires a proxy secret and an authenticating loopback reverse proxy"
        )
  end

  turn_urls = get.("turn_urls", "MF_TURN_URLS", "")
  unless is_binary(turn_urls), do: raise("Invalid Exam TURN URLs")

  urls =
    turn_urls
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  unless Enum.all?(urls, &Regex.match?(~r/\Aturns?:[^\s,]+\z/, &1)),
    do: raise("MF_TURN_URLS must contain turn: or turns: URLs")

  turn_secret = secret.("turn_secret", "MF_TURN_SECRET")
  relay? = get.("relay_only", "MF_RELAY_ONLY", nil) in [true, "1"]

  if (relay? or urls != []) and
       (urls == [] or !is_binary(turn_secret) or byte_size(turn_secret) < 32),
     do: raise("TURN requires URLs and a secret of at least 32 bytes")

  cert = get.("device_tls_certfile", "MF_DEVICE_TLS_CERTFILE", nil)
  key = get.("device_tls_keyfile", "MF_DEVICE_TLS_KEYFILE", nil)
  if is_nil(cert) != is_nil(key), do: raise("Configure both device TLS certificate and key")

  if cert do
    unless is_binary(cert) and is_binary(key), do: raise("Invalid Exam device TLS paths")
    address = get.("device_bind_ip", "MF_DEVICE_BIND_IP", "127.0.0.1")

    bind_ip =
      case is_binary(address) && :inet.parse_address(String.to_charlist(address)) do
        {:ok, parsed} -> parsed
        _ -> raise "Invalid Exam device bind address"
      end

    tls_port =
      parse_port.(get.("device_tls_port", "MF_DEVICE_TLS_PORT", "4443"), "Invalid Exam device TLS port")

    config :mf_exam, MedFabric.ExamWeb.Endpoint,
      https: [
        ip: bind_ip,
        port: tls_port,
        certfile: cert,
        keyfile: key
      ]
  end

  if sidecar = get.("preview_url", "MF_PREVIEW_URL", nil) do
    uri = parse_uri.(sidecar, "Invalid Preview feed URL")

    unless uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost"],
      do: raise("Invalid Preview feed URL")

    preview_secret =
      required.("preview_credential_file", "MF_PREVIEW_CREDENTIAL_FILE")
      |> read_file.("Unreadable Preview credential")
      |> String.trim()

    if byte_size(preview_secret) < 32, do: raise("Preview credential requires at least 32 bytes")
    config :mf_exam, :sidecar, %{url: sidecar, secret: preview_secret}
  end

  deployment_uuid = required.("deployment_uuid", "MF_DEPLOYMENT_UUID")
  unless is_binary(deployment_uuid) and Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, deployment_uuid), do: raise("A valid immutable deployment UUID is required")

  config :mf_exam, :lab, %{
    deployment_uuid: deployment_uuid,
    public_origin: origin,
    device_enabled: not is_nil(cert),
    encounters: entries,
    local?: local?,
    proxy_secret: if(local?, do: nil, else: proxy_secret),
    turn: %{urls: urls, secret: turn_secret, relay?: relay?},
    database_url:
      secret.("database_url", "DATABASE_URL") || raise("Missing database_url credential"),
    artifact_dir: Path.expand(required.("artifact_dir", "MF_ARTIFACT_DIR"))
  }

  # The Weld application bootstrap can apply runtime endpoint options
  # independently of the static configuration.
  config :mf_exam, MedFabric.ExamWeb.Endpoint,
    adapter: Bandit.PhoenixAdapter,
    render_errors: [formats: [html: MedFabric.ExamWeb.ErrorHTML], layout: false],
    pubsub_server: MedFabric.Exam.PubSub,
    live_view: [signing_salt: "med_fabric_exam_lv_salt"],
    server: true,
    check_origin: if(local?, do: ["//localhost:#{port}", "//127.0.0.1:#{port}"], else: [origin]),
    url: [scheme: public_uri.scheme, host: public_uri.host, port: public_uri.port],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base:
      secret.("secret_key_base", "MF_SECRET_KEY_BASE") ||
        raise("Missing secret_key_base credential")
end
