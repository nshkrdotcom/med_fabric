import Config

if config_env() == :test do
  config :mf_preview, :listen, port: 0, secret: "synthetic-preview-test-credential"
end
