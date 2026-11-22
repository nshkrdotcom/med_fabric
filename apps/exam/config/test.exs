import Config

config :mf_exam, MedFabric.ExamWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false,
  secret_key_base: String.duplicate("test-", 16)

config :logger, level: :warning
