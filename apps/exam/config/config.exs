import Config

config :mf_exam, MedFabric.ExamWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  pubsub_server: MedFabric.Exam.PubSub,
  live_view: [signing_salt: "med_fabric_exam_lv_salt"],
  secret_key_base:
    "med_fabric_exam_dev_secret_key_base_0123456789abcdefghijklmnopqrstuvwxyz_0123456789"

config :phoenix, :json_library, Jason

if File.exists?(Path.expand("#{config_env()}.exs", __DIR__)) do
  import_config "#{config_env()}.exs"
end
