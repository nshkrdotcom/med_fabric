import Config

if System.get_env("MF_LAB") == "1" do
  encounters = System.fetch_env!("MF_ENCOUNTERS_FILE") |> File.read!() |> Jason.decode!()

  entries =
    for entry <- encounters, into: %{} do
      %{"exam" => id, "patient_actor" => patient, "clinician_actor" => clinician,
        "patient_ref" => patient_ref, "encounter_ref" => encounter_ref,
        "destination" => destination} = entry

      unless Regex.match?(~r/\A[a-zA-Z0-9-]{1,48}\z/, id) and
               Enum.all?([patient, clinician, destination], &(is_binary(&1) and &1 != "")) and
               patient != clinician and Regex.match?(~r/\APatient\/[A-Za-z0-9.\-]{1,64}\z/, patient_ref) and
               Regex.match?(~r/\AEncounter\/[A-Za-z0-9.\-]{1,64}\z/, encounter_ref) do
        raise "Invalid encounter configuration for #{inspect(id)}"
      end

      {id, entry}
    end

  unless is_list(encounters) and encounters != [] and map_size(entries) == length(encounters),
    do: raise("MF_ENCOUNTERS_FILE must contain a nonempty array with unique exam IDs")

  port = String.to_integer(System.get_env("MF_HTTP_PORT", "4000"))
  origin = System.get_env("MF_PUBLIC_ORIGIN", "http://localhost:#{port}")
  uri = URI.new!(origin)
  local? = uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1"] and uri.port == port

  unless uri.host && (local? or uri.scheme == "https") and
           uri.path in [nil, "", "/"] and is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
    do: raise("MF_PUBLIC_ORIGIN must be a localhost HTTP origin or a public HTTPS origin")

  proxy_secret = System.get_env("MF_PROXY_SECRET")

  if local? do
    keys = Enum.flat_map(encounters, &[&1["patient_key"], &1["clinician_key"]])
    unless Enum.all?(keys, &(is_binary(&1) and byte_size(&1) >= 32)) and
             length(Enum.uniq(keys)) == length(keys),
      do: raise("Local encounter access keys must be unique and at least 32 bytes long")
  else
    unless is_binary(proxy_secret) and byte_size(proxy_secret) >= 32,
      do: raise("HTTPS operation requires MF_PROXY_SECRET and an authenticating loopback reverse proxy")
  end

  urls = System.get_env("MF_TURN_URLS", "") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  unless Enum.all?(urls, &Regex.match?(~r/\Aturns?:[^\s,]+\z/, &1)),
    do: raise("MF_TURN_URLS must contain turn: or turns: URLs")
  turn_secret = System.get_env("MF_TURN_SECRET")
  relay? = System.get_env("MF_RELAY_ONLY") == "1"
  if (relay? or urls != []) and (urls == [] or !is_binary(turn_secret) or byte_size(turn_secret) < 32),
    do: raise("TURN requires MF_TURN_URLS and a 32-byte or longer MF_TURN_SECRET")

  config :mf_exam, :lab, %{
    encounters: entries,
    local?: local?,
    proxy_secret: if(local?, do: nil, else: proxy_secret),
    turn: %{urls: urls, secret: turn_secret, relay?: relay?},
    database_url: System.fetch_env!("DATABASE_URL"),
    artifact_dir: Path.expand(System.fetch_env!("MF_ARTIFACT_DIR"))
  }

  config :mf_exam, MedFabric.ExamWeb.Endpoint,
    server: true,
    check_origin: if(local?, do: ["//localhost:#{port}", "//127.0.0.1:#{port}"], else: [origin]),
    url: [scheme: uri.scheme, host: uri.host, port: uri.port],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: System.fetch_env!("MF_SECRET_KEY_BASE")
end
