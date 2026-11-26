import Config

config :mf_exam, MedFabric.ExamWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: MedFabric.Exam.PubSub,
  server: false

config :mf_preview, :listen, port: 0, secret: String.duplicate("example-", 4)
config :med_ex, :rtc_provider, MedEx.RTC.Provider

config :logger, level: :info
