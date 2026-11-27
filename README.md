# Med Fabric

Med Fabric 0.3.0 coordinates source-preserving examination acquisition, native
clinical review and independent delivery. It uses MedEx 0.4.0 technical contracts
and protocol revision 2. Browser microphone and paired waveform inputs share
one writer/journal/manifest path; PLX is event-only, and manual pulse is native
clinical evidence awaiting an explicit clinician decision.

| Published package | Version | Construction | Purpose |
|---|---|---|---|
| mf_exam | 0.3.0 | Weld monolith | Clinical host plus private Domain/Store/Interop |
| mf_handheld | 0.3.0 | Direct Mix | Device source, bounded durable spool and uploader |
| mf_preview | 0.3.0 | Direct Mix | Optional isolated Opus/WebRTC monitoring |

Exam and Handheld require `med_ex ~> 0.4.0` and no media providers. Preview requires
the base and concrete `med_ex_opus ~> 0.3.0`/`med_ex_rtc ~> 0.3.0`. Domain, Store
and Interop are private source components of the Exam artifact, never public
packages. Exactly two Weld artifacts and four direct Mix packages span both repos.

## Runtime behavior

Exam derives device or patient authority at the transport boundary, reserves a
fence, and commits durable receipts before ACK. Clients match the current
connection incarnation; a historical ACK cannot renew permission. Unknown
filesystem/DB outcomes retire the writer and require positive effect quiescence
and verified recovery. Browser capture retains only bounded current-page buffers;
page death cannot claim offline continuity.

Pure Domain validates evidence and selections. One Store transaction commits a
native decision, immutable observations and export intent. Missing FHIR config,
unrepresentable mapping or network failure cannot undo valid acceptance. The
outbox independently pins identity/resource/destination and records blocked,
unresolved, retryable, conflict or confirmed outcomes with safe retry predicates.

Verified manifest/index/segment routes serve exact bounded bytes. Optional Preview
runs in another BEAM and cannot block recording/review. Direct browser talkback
has independent call authorization and cooperating-client renewal/teardown;
server signaling cannot forcibly stop established direct P2P media.

## Development

The six application targets are `core/domain`, `core/store`, `core/interop`,
`apps/exam`, `apps/handheld` and `apps/preview`. The root remains an empty
coordinator: it contributes genuine tooling lint/tests and overview docs to
quality, but is never a Dialyzer target. `tools/maintainer` remains a private
compile boundary. A test path requires explicit `--project`; root-relative
paths are never broadcast into six unrelated projects.

## Root command contract

Both repositories expose the following source-development commands. They use
released Blitz 0.4.1 with at most two concurrent project processes by default;
`--jobs 1` through `--jobs 4` select the bound. `ERL_FLAGS` defaults to `+S 4:4`.
These are repository wrapper options, not guessed Blitz task passthrough syntax.

| Command | Default behavior |
|---|---|
| `mix setup` | Fetch genuine root tooling first, then each real project's dev/test/prod dependencies; no upgrade-all. |
| `mix test` | Run all ordinary application suites once, with test compilation and warnings as errors. |
| `mix credo` | Strict Credo in every real application, with exact nonempty source-inventory comparison. |
| `mix dialyzer` | Analyze each real application's nonempty own BEAM inventory using its existing PLT context. |
| `mix quality` | Format, warning-free dev/test compile, ordinary tests, strict Credo, Dialyzer and docs; include private boundary/root tooling checks. |
| `mix docs` | Build root overview and application documentation with warnings as errors. |

Use `mix setup --locked` only after real locks are resolved; it adds
`deps.get --check-locked`. `mix quality --release` adds warning-free production
compilation. `mix quality --project PATH` repeats only an affected project;
`mix test --project PATH -- test/file_test.exs:42 --seed 0 --max-cases 2` forwards
native test arguments to that project. Native leaf commands remain available
from the leaf directory. Quality/setup reject stray arguments. Root Credo is
always strict; use a native leaf task for deliberately focused lint.

Each project owns its dependency, build, lock and PLT paths. Unset inherited
`MIX_EXS`, `MIX_BUILD_PATH`, `MIX_BUILD_ROOT`, `MIX_DEPS_PATH` and `MIX_LOCKFILE`.
The root runner invokes native tasks without recursive aliases; startup tests
exercise fetched-but-uncompiled dependencies and real Blitz failure propagation.
A missing expected suite, empty BEAM set or incomplete Credo inventory fails.
Cold PLTs can be slow; valid PLTs are not forcibly rebuilt. Root commands do not
start PostgreSQL, HAPI, TURN, browsers, physical ENOSPC or long capture runs.

The implementation environment lacked Elixir/Mix. The command contract and new
Elixir regressions require real workstation compilation and execution before
release; no source documentation asserts an unobserved passing gate.

`.mix_sources.json` is the sole development source selector. Choose trusted paths,
exact Git refs or ordinary/signed registry packages for the three upstream SDK
packages. Internal component paths stay fixed. Example for a sibling checkout:

```json
{
  "med_ex": {"path": "../med_ex"},
  "med_ex_opus": {"path": "../med_ex/extensions/med_ex_opus"},
  "med_ex_rtc": {"path": "../med_ex/extensions/med_ex_rtc"}
}
```

Source contexts isolate deps/build/locks; detached packages use normal Hex
requirements. Do not fabricate candidate lock checksums. See the
[release guide](guides/releasing_exam.md) for source freeze and exact artifacts.

## Operations

Provision fresh revision-2 DB, evidence and spool namespaces. Bind immutable
deployment UUID to DB and root, enforce exclusive local service ownership and
verify installed SQL/assets before listener activation. Preserve prior evidence
in approved checksummed offline archives. Restoring an older backup requires
accounting for later irreversible evidence and external writes; otherwise remain
non-writable. No automatic destructive reset or writable restore clone.

Synthetic/reference qualification proves software behavior, not sensor
calibration or clinical readiness. See the [failure matrix](guides/failure_matrix.md),
[clinical boundary](guides/security_and_clinical_boundary.md),
[private core guide](guides/clinical_core.md), and package READMEs.
