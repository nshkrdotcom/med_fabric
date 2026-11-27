# Six-package installed smoke

This private Mix consumer installs exact coordinated candidates:

| Package | Version | Artifact owner |
|---|---|---|
| med_ex | 0.4.0 | Weld prepared SDK |
| med_ex_opus | 0.3.0 | Direct Mix provider |
| med_ex_rtc | 0.3.0 | Direct Mix provider |
| mf_exam | 0.3.0 | Weld prepared monolith |
| mf_handheld | 0.3.0 | Direct Mix client |
| mf_preview | 0.3.0 | Direct Mix sidecar |

Copy this directory to a directory outside both repositories. Resolve it against
the authenticated signed candidate registry during qualification, then against
the official registry after the separately authorised release. Keep exact locks
and archive/checksum identities. Candidate checksums are generated from actual
archives; no checksum is guessed or copied from an earlier release.

```sh
mix deps.get
mix compile --warnings-as-errors
mix test --warnings-as-errors
```

Once the exact lock exists, repeat dependency resolution with `--check-locked`.
Elixir 1.20, compatible OTP, native compiler, make, pkg-config, OpenSSL development
headers and loopback UDP are required. The Opus package verifies its pinned source
before every cache use. An explicitly selected offline source must be absolute,
readable and match the pin.

Tests check API revision 2, Exam-owned browser assets, absence of SDK browser
assets, a synthetic PLX reading through the SDK codec, and actual PCM encoding
and RTP delivery through isolated Preview ownership and the concrete Opus/RTC
capabilities. Preview uses a bounded purpose/source/generation/viewer capability;
no application-global provider selection exists. The local test listener uses an
ephemeral port. These smoke tests require neither a database nor a browser; they
do not replace the detached native browser, PostgreSQL/HAPI, TLS, loss/recovery,
conditional-create or full duration ext4 qualification gates.
