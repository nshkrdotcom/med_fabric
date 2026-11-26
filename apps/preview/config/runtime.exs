import Config

path = "/etc/med_fabric/preview.json"

listen =
  if config_env() != :test and File.regular?(path) do
    %{"port" => port, "credential_file" => credential_file} =
      path |> File.read!() |> Elixir.JSON.decode!()

    {port, credential_file}
  else
    if credential_file = System.get_env("MF_PREVIEW_CREDENTIAL_FILE") do
      {String.to_integer(System.fetch_env!("MF_PREVIEW_PORT")), credential_file}
    end
  end

if listen do
  {port, credential_file} = listen
  unless is_integer(port) and port in 1..65535, do: raise("Invalid Preview port")
  secret = credential_file |> File.read!() |> String.trim()
  if secret == "", do: raise("Empty Preview credential")
  config :mf_preview, :listen, port: port, secret: secret
end

config :med_ex, :rtc_provider, MedEx.RTC.Provider
