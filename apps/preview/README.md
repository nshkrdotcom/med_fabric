# Isolated monitor

This optional Mix application holds a loopback HTTP feed and native MedEx Opus/RTC peers. Each feed is authenticated with a dedicated private credential. Viewer operations require short-lived acquisition/viewer tokens signed by Exam. No database, device enrollment key or authoritative artifact path is configured in the process. Start the service under an account or mount namespace that can only read its own configuration and build. See [preview isolation](../../guides/preview_isolation.md).

Preview selects the base MedEx SDK, Opus, and RTC from one compatible
source family. Build it with ordinary Mix in this directory, using
`mix deps.get` and `mix test`, or use `MIX_ENV=prod mix deps.get` and
`MIX_ENV=prod mix release` for deployment.
