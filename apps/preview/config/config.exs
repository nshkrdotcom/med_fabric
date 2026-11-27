import Config

config :logger, level: :info

if config_env() == :test do
  config :mf_preview, :listen,
    port: 0,
    secret: "synthetic-preview-test-credential-32",
    trusted_clock: true,
    clock_error_ms: 2_000,
    max_peers: 8,
    max_source_peers: 2,
    ice_servers: [],
    ice_transport_policy: :all
end
