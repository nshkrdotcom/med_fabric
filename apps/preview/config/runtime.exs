import Config

config :logger, level: :info

if config_env() != :test do
  path = System.get_env("MF_PREVIEW_CONFIG") || "/etc/med_fabric/preview.json"

  config =
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= 16_384 ->
        case JSON.decode(bytes) do
          {:ok, value} when is_map(value) -> value
          _ -> raise "Invalid Preview configuration"
        end

      _ ->
        raise "Missing Preview configuration"
    end

  allowed =
    ~w(port credential_file trusted_clock clock_error_ms max_peers max_source_peers ice_servers ice_transport_policy)

  unless Enum.all?(Map.keys(config), &(&1 in allowed)),
    do: raise("Unknown Preview configuration setting")

  credential = System.get_env("MF_PREVIEW_CREDENTIAL_FILE") || config["credential_file"]

  unless is_binary(credential) and Path.type(credential) == :absolute,
    do: raise("Invalid Preview credential path")

  secret =
    case File.read(credential) do
      {:ok, bytes} when byte_size(bytes) in 32..4097 -> String.trim(bytes)
      _ -> raise "Unreadable Preview credential"
    end

  port =
    case System.get_env("MF_PREVIEW_PORT") do
      nil ->
        config["port"]

      value ->
        case Integer.parse(value) do
          {number, ""} when number in 1..65_535 -> number
          _ -> raise "Invalid Preview port"
        end
    end

  unless is_integer(port) and port in 1..65_535, do: raise("Invalid Preview port")

  policy =
    case config["ice_transport_policy"] || "all" do
      "all" -> :all
      "relay" -> :relay
      _ -> raise "Invalid Preview ICE policy"
    end

  config :mf_preview, :listen,
    port: port,
    secret: secret,
    trusted_clock: config["trusted_clock"] == true,
    clock_error_ms: config["clock_error_ms"] || 2_000,
    max_peers: config["max_peers"] || 32,
    max_source_peers: config["max_source_peers"] || 4,
    ice_servers: config["ice_servers"] || [],
    ice_transport_policy: policy
end
