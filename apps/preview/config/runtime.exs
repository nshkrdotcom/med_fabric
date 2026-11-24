import Config
if secret=System.get_env("MF_PREVIEW_CREDENTIAL_FILE") do
  config :mf_preview,:listen,port: String.to_integer(System.fetch_env!("MF_PREVIEW_PORT")),secret: File.read!(secret) |> String.trim()
end
config :med_ex,:rtc_provider,MedEx.RTC.Provider
