import Config

config :mf_exam, MedFabric.ExamWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: MedFabric.Exam.PubSub,
  server: false

config :mf_preview, :listen,
  port: 0,
  secret: String.duplicate("example-", 4),
  clock_error_ms: 100,
  trusted_clock: true

config :logger, level: :info
