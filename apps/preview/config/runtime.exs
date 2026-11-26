import Config

path = "/etc/med_fabric/preview.json"

if config_env() != :test and File.regular?(path) do
  %{"port" => port, "credential_file" => credential_file} =
    path |> File.read!() |> Elixir.JSON.decode!()

  unless is_integer(port) and port in 1..65535, do: raise("Invalid Preview port")

  config :mf_preview, :listen,
    port: port,
    secret: File.read!(credential_file) |> String.trim()
else
  if secret = System.get_env("MF_PREVIEW_CREDENTIAL_FILE") do
    config :mf_preview, :listen,
      port: String.to_integer(System.fetch_env!("MF_PREVIEW_PORT")),
      secret: File.read!(secret) |> String.trim()
  end
end

config :med_ex, :rtc_provider, MedEx.RTC.Provider
