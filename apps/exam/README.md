<p align="center">
  <img src="https://raw.githubusercontent.com/nshkrdotcom/med_fabric/main/apps/exam/assets/exam.svg" alt="Med Fabric Exam logo" width="200" />
</p>

# Med Fabric Exam

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric/tree/main/apps/exam"><img src="https://img.shields.io/badge/GitHub-mf__exam-345366" alt="GitHub source" /></a>
  <a href="https://github.com/nshkrdotcom/med_fabric/blob/main/apps/exam/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_exam` **0.3.0** is the Phoenix/LiveView host for revision-2 acquisition,
verified evidence review, native clinical acceptance and independently durable
FHIR delivery. It is the one Weld monolith in this repository: private Domain,
Store and Interop components are composed into the installed `mf_exam` application.
They are not separate public packages.

```elixir
def deps, do: [{:mf_exam, "~> 0.3.0"}]
```

The package requires Elixir `~> 1.20`, its qualified OTP toolchain, PostgreSQL,
base `med_ex ~> 0.4.0`, a dedicated service-owned artifact root and an immutable
deployment UUID. Production capture requires the host's exclusive OS root lock.
Use fresh revision-2 database/artifact/spool roots; startup rejects an older,
partial, mismatched or modified schema rather than migrating it implicitly.

## Workflows

| Source | Evidence and authority |
| --- | --- |
| Paired handheld | Enrolled device, clinician grant, diagnostic audio and ECG through the common fenced writer |
| Browser microphone | Patient session, server-created acquisition and same-page volatile MEX1 producer through that same writer |
| PLX spot check | Canonical measurement events and immutable collection inventory; no dummy waveform stream |
| Manual pulse | Immutable native manual evidence, followed by a separate clinician decision |
| Talkback | Independent direct browser media with call/session-bound cooperative renewal |
| Optional Preview | Separate `mf_preview ~> 0.3.0` process, bounded feed and signed viewer capability |

Waveform evidence consists of immutable raw segments, journal, verified index
and deterministic manifest. Playback synthesizes a WAV header for one verified
segment. It does not create a continuous-WAV evidence format, insert samples for
gaps or turn a waveform review into a synthetic clinical observation.

Clinical acceptance commits native decisions, observations and delivery intents
atomically. Mapping, destination lookup and HTTP occur afterward. Missing export
configuration or an unsupported representation blocks delivery while retaining
valid native acceptance. Unknown remote effects remain unresolved until the
outbox can prove a safe next action under the same external identifier.

## Running and qualification

See [Getting Started](guides/getting_started.md) for `/etc/med_fabric/exam.json`,
release overlays and local operation, [Browser to Record](guides/browser_to_record.md)
for capture/review semantics, [Handheld Integration](guides/handheld_integration.md)
for source authority, and [Architecture](guides/architecture.md) for ownership.

The package contains its own `exam.js`, `acquisition.js` and
`acquisition_worklet.js` assets. It has no codec/RTC runtime dependency. Preview
is built and run separately with concrete `med_ex_opus` and `med_ex_rtc` packages.

Run formatting, warning-free compilation, unit/integration tests, strict Credo,
Dialyzer and ExDoc before packaging. Required PostgreSQL/HAPI/TLS/browser/native
fixtures must fail when absent from an explicitly selected qualification lane;
a source-only test run does not qualify a deployment. Both Preview-off and
isolated-Preview native runs, fault injection, ext4 exhaustion and the full
1,740-second soak are release gates.

**License:** [MIT](LICENSE).
