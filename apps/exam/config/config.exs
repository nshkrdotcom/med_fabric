import Config

config :logger, level: :info

config :mf_exam, MedFabric.ExamWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: MedFabric.ExamWeb.ErrorHTML], layout: false],
  url: [host: "localhost"],
  pubsub_server: MedFabric.Exam.PubSub,
  live_view: [signing_salt: "med_fabric_exam_lv_salt"]

config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "authorization",
  "password",
  "secret",
  "session",
  "key",
  "token",
  "stream_token",
  "creation",
  "lease",
  "sdp",
  "candidate",
  "event",
  "body",
  "resource",
  "value"
]

if File.exists?(Path.expand("#{config_env()}.exs", __DIR__)) do
  import_config "#{config_env()}.exs"
end
