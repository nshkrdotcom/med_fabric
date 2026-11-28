# Coordinated release and qualification

## Fixed package topology

| Package | Candidate | Construction | Runtime ecosystem dependencies |
|---|---|---|---|
| med_ex | 0.4.0 | Weld package projection | none |
| med_ex_opus | 0.3.0 | Direct Mix extension | none |
| med_ex_rtc | 0.3.0 | Direct Mix extension | none |
| mf_exam | 0.3.0 | Weld monolith | med_ex ~> 0.4.0 |
| mf_handheld | 0.3.0 | Direct Mix app | med_ex ~> 0.4.0 |
| mf_preview | 0.3.0 | Direct Mix app | base ~> 0.4.0, both providers ~> 0.3.0 |

Check official registry and local/remote package tags before reserving candidates.
Numbers in source are selected versions, not evidence that they remain unused.
Never reuse an existing publication. Preserve factual historical changelogs.

## Source and build gates

Freeze both clean source SHAs, executable Git modes and six version identities.
Read installed Weld and Hex task help; MedEx's private maintainer project requires Weld
~> 0.20.3. Use the pinned `.tool-versions`. Record actual compiler/native archive,
OS/filesystem, browser, PostgreSQL and HAPI versions. Do not print secrets.

Use `med_ex/tools/maintainer` as the Weld invoker for both repositories, passing
each repository's absolute `build_support/weld.exs` manifest and sole artifact
(`med_ex` or `mf_exam`): `mix weld setup`, `mix weld project`,
`mix weld verify`, `mix weld prepare`, `mix weld status`. Verify current task syntax
first. Preserve exact prepared identity and archive; never edit generated files,
the v2 current pointer, tags or stale-check controls to bypass a failure.

For each direct package, resolve the exact candidate closure, run formatting,
warning-free compilation, all tests, Credo, Dialyzer and ExDoc warnings-as-errors,
then `mix hex.build`. Preserve the actual resulting archive and checksum.
Compare package files to its authoritative package inventory. Private components
and maintainer tools never become runtime packages. The base root Mix project
is not a second release candidate.

An unpublished dependency has no genuine official checksum. Existing third-party
lock entries are retained; resolve six-family entries using the signed candidate
registry and commit the resulting actual locks before candidate freeze. Never
substitute a guessed version or checksum. Changed lock/content invalidates proof.

### Prepare unpublished candidates

From the clean, committed SDK and Fabric checkouts, run the maintained two-step
candidate builder. Choose a **new private evidence directory outside both repositories**:

```sh
cd /absolute/path/to/med_ex
build_support/prepare_candidates.sh sync /private/new-candidate-evidence
```

`sync` runs SDK source qualification and its existing Weld preparation, retains
three exact upstream archives from the signed candidate registry and refreshes
only the five dependent Fabric locks using ordinary Mix dependency resolution.
It retains the previous lock bytes and rejects changes to third-party version,
registry and checksum pins. It stops before committing anything. If synchronization
fails, inspect the retained before-locks and source diffs before retrying.

Review and commit the actual Fabric lock changes. Then run:

```sh
build_support/prepare_candidates.sh build /private/new-candidate-evidence
```

`build` requires both repositories to be clean and the synchronized locks to
match the retained bytes. The existing prepared registry helper rebuilds the
two direct upstream provider tarballs, and the builder requires all three
served upstream archives to match the retained checksums. It prepares Exam
using the existing Weld entry point and explicit candidate registry URL/key,
builds Handheld and Preview with their locked dependencies, and passes the
six-archive manifest through the existing detached-artifact verifier. The
result is `candidate-inputs.json`; separate downstream build attempts retain
their own evidence. These are candidates, not proof of qualification or publication.
The builder never publishes, pushes, commits or provisions external tools.
The checked-in combined smoke lock is not used for this workflow: the detached
combined consumer resolves and retains its own genuine six-package lock.

### Exact archive inputs for native gates

`ops/qc_native.sh` requires `--artifacts MANIFEST.json` for the full suite and
each 1740-second soak. `ops/qc_detached_release.sh REPORT.json --artifacts
MANIFEST.json` accepts the same input. The manifest is qualification evidence,
not a builder: obtain the actual six archives and both prepared `bundle.json`
files through the construction steps above first. The scripts do not rebuild a
candidate or substitute a checkout package.

The JSON object has schema `medfabric.detached_inputs.v2`, a `registry` value of
`candidate` or `official`, and a `packages` object with exactly the six package
names from the release matrix. Each package entry contains:

| Field | Required value |
|---|---|
| `archive` | Actual Hex tar path, absolute or relative to the manifest directory |
| `sha256` | Lowercase 64-character outer SHA-256 of those exact tar bytes |
| `source_revision` | Lowercase 40-character frozen Git revision; one revision per repository |
| `build` | `weld` for `med_ex` and `mf_exam`; `mix` for the four direct packages |
| `prepared_release` | For the two Weld entries only: the actual prepared `bundle.json` path |

The verifier reads the version and construction from the checked-in release
matrix. It checks each archive's actual metadata, declared file inventory,
bounded dependencies, executable modes and contents. Each Weld identity must
bind that archive checksum and source revision. The role consumers install
ordinary exact-version Hex dependencies under the caller's configured signed
candidate registry or the official `https://repo.hex.pm` origin. The scripts
force signature, origin and TLS verification and refuse embedded URL
credentials or mirror substitution. A candidate registry cannot be labelled as
official proof.

Each role starts from a new external consumer directory. Installed locks and
every archived source file are compared with the supplied bytes before
compilation and again before native acceptance. Exam and Preview configuration
must exist in their installed packages. The detached release checks refuse
private component and maintainer OTP applications; Exam and Handheld also
refuse the native media dependency closure. The combined Hex example runs
against the same six archives before the separate process proof. The full native
runner prepares the three role consumers once and re-verifies their archive,
registry, lock and installed-file identities before production release assembly.
Standalone `qc_detached_release.sh` still creates fresh consumers; the full
runner passes its own `--native-evidence` directory to avoid recompilation.
The existing root Blitz coordinator compiles and assembles the independent role
projects in parallel, after serial locked resolution and installed-file verification.
Run the normal workspace setup before qualification; the runner does not provision
Blitz or other tools. Phase timings are written to the native run log. Reports retain
the manifest checksum, package/source/prepared identities, resolved locks,
installed file inventories and the registry evidence.

For an unpublished six-package manifest, the existing SDK registry runner can
verify and serve those exact archives without rebuilding them:

```sh
cd /absolute/path/to/med_ex
build_support/check_consumers.sh --registry \
  --registry-manifest /private/candidate-inputs.json -- \
  ./build_support/qualify_ecosystem.sh full --gate fabric-native \
  --artifacts /private/candidate-inputs.json --evidence /private/evidence
```

The sibling `med_fabric` release verifier validates the complete manifest before
registry construction. The runner signs the candidate registry with its private
key, uses Erlang's loopback HTTP server, and resolves third-party tarballs from
actual SDK/provider and Fabric app/core lockfiles. It checks tarball checksums
before use; it neither serves an official family fallback nor changes the user's
Hex configuration. External tools must already satisfy native preflight. This
command is candidate proof only. A new registry invocation creates a new private
Hex home, key and URL, so receipt reuse across registry restarts is not guaranteed.
For official proof, use the verified official Hex configuration instead.

### Rerun both candidate soaks

From this repository's root, run the Fabric wrapper with both clean checkouts side by side.

```sh
./ops/soak.sh
```

The wrapper builds six candidate archives using the SDK candidate builder, commits
any verified changes to the five Fabric dependency locks, and starts the signed
registry. It runs the native soak with Preview off, then isolated, for 1,740 seconds
each on ext4. Set `SOAK_EXT4_BASE` to an existing writable ext4 directory
(default `/var/tmp`). Provide the native preflight tools, including `turnserver`
on PATH, and the pinned Opus archive via `MED_EX_OPUS_TARBALL` or the SDK cache.

Startup prints one `tail -F` command for the live log. It follows candidate
preparation, archive construction, and native soak progress. The first failure
stops the run.
The two `qualification/soak-*/native.json` reports are standalone candidate
evidence. For coordinated release receipts and prerequisite gates, including native
and physical ENOSPC, use the ecosystem runner with `--gate fabric-soak-isolated`.

Run the three mandatory native branches from the Med Fabric repository with
distinct evidence directories (within the candidate registry command for
unpublished packages, or under the official registry for published packages):

```sh
ops/qc_native.sh --suite all --artifacts /private/candidate-inputs.json \
  --evidence /private/evidence/native
ops/qc_native.sh --suite soak --seconds 1740 --preview off \
  --volume /mnt/qualified-ext4 --artifacts /private/candidate-inputs.json \
  --evidence /private/evidence/soak-off
ops/qc_native.sh --suite soak --seconds 1740 --preview isolated \
  --volume /mnt/qualified-ext4 --artifacts /private/candidate-inputs.json \
  --evidence /private/evidence/soak-on
```

The full suite requires isolated Preview. Soak refuses a filesystem whose
observed type is not ext4, and the 1740-second report must pass the fixed soak
verifier. Explicit `--med-ex-project` is confined to paired or short source
diagnostics; it cannot satisfy an archive or release soak gate. Browser release
verification similarly requires `--installed-consumers` from the native gate.
The focused tooling tests are `python3 ops/qc_native_test.py` and
`elixir ops/detached_artifacts_test.exs`; these do not replace native execution.

## Native qualification

Use this release guide together with the checked-in qualification runners
(`build_support/qualify_ecosystem.sh`, `ops/qc_detached_release.sh`,
`ops/qc_native.sh`) and report verifiers (`ops/verify_native_report.jq`,
`ops/verify_soak_report.jq`) as the authoritative release gate. Record
PASS/FAIL/BLOCKED/NOT RUN with actual command, exit, count, fixture
hash, exact source/archive identity and sanitized evidence. Static checks are
only one gate. Required checks include:

- Compiled/public API and deletion inventories, transitive runtime dependencies,
  ExDoc links/assets and fresh revision refusal.
- Receipt vectors across SDK, writer/storage, Exam, Handheld and browser; malformed
  state, exact progression, replay/gap, limits and storage resource transfer.
- Real filesystem and PostgreSQL kill barriers before and after journal sync,
  in-flight effect quiescence, delayed historical ACK, local reclaim crash,
  terminal/index/manifest staging recovery and physical ext4 ENOSPC.
- Native Domain validity, atomic decision/observations/intents without export
  configuration, exact authorized request replay after closure and native manual
  evidence source constraints.
- Actual HAPI conditional create/readback, response loss, stale sender and lease
  turnover, permanent proven noncommit, unsafe duplicate possibility, pinning,
  blocked remediation, bounded retry exhaustion and immutable confirmation.
- Real microphone/worklet buffering/PCM/tail/drain/reload, verified segment bytes,
  direct talkback renewal/teardown and its cooperating-client enforcement limits.
- Real pinned Opus decode/native lifecycle and independent RTC receiver, direct
  and relay-only TURN, isolated Preview expiry/fault/churn and raw continuity.
- Fresh/partial/wrong schema/root identities, startup from installed SQL/assets,
  service ownership and coordinated restore including later irreversible effects.
- Independent SDK CLI and private clinical host, six detached artifacts and real
  separate Exam/Handheld/Preview BEAMs; combined smoke is not isolation proof.
- Two clean 1740-second ext4 soaks: Preview off and isolated monitoring active.
  Retain 5000 ms sampling, 10000 ms warmup, 15000 ms startup, 2000 ms lag budget
  and failure after two consecutive violations. Run controlled fault phases
  separately; do not relax clean-run criteria. Measure queues, exact oracle,
  p50/p95/p99 latency, O(k) reclamation and bounded segment-read work.

## Publication and activation transaction

Do not publish until the owner explicitly authorizes it and every provisional
all-six gate passes. Publish the three upstream exact qualified archives first;
verify official downloaded bytes, metadata and checksum. Refresh downstream
locks against actual official upstream packages. Rebuild changed downstream
archives and rerun affected and whole-family gates before publishing them.
Preserve outer SHA-256 separately from Hex/registry checksums.

After all six official archives exist, perform the full official detached native,
isolated, fault and soak qualification. Tags alone are not proof. No partial
activation, source fallback or mixed revision deployment. Stop on any failed or
NOT RUN mandatory gate. If a published package needs correction, select a new
unused version and qualify its affected closure; never overwrite.

## Data and deployment

Inventory DB, evidence/spool roots, credential authorities and external
destinations by metadata only. Preserve non-disposable data in approved checksummed
offline archives and prove recoverability before any destructive operation.
Provision new empty revision-2 namespaces with one immutable deployment UUID
in DB and root. Require one authoritative capture service with exclusive trusted
local root ownership, no simultaneous writable clones or shared filesystem
failover. Lock loss is fatal; restart only after all old workers/OS effects quiesce.

A coherent older backup does not prove no later evidence, decisions, reclaimed
source or external writes exist. Account for the cut point using trusted later
state and pinned external identities; never reconstruct clinical decisions from
remote resources or invent IDs. Block affected admission/dispatch if uncertain,
or the whole namespace if scope cannot be bounded. No automatic reset or
compatibility rollback into new data. Activation is a separately authorized step.

## Ecosystem gates and retained reports

The signed candidate registry is private staging evidence. It is not an official
publication receipt. Supply its authenticated configuration in a private Hex
home, then obtain and commit real candidate lock entries before `--check-locked`
gates. Retain archive SHA-256 and registry checksums separately.

The ecosystem runner has explicit `fabric-native`, `medex-enospc`,
`fabric-soak-off` and `fabric-soak-isolated` gates. Full soak qualification requires
`--volume` on ext4 and exactly 1740 seconds, plus `--artifacts`. Physical exhaustion
requires a separate `--enospc-root` dedicated loop mount with the exact marker
specified in the SDK technical contract. A short soak is diagnostic only.
`ops/verify_soak_report.jq` checks exact sample counts, unchanged lag policy,
actual latency samples, bounded resource maxima, linear reclamation work and
sustained decoded media for isolated Preview. Preserve both reports and inputs.

Use `--gate fabric-soak-isolated` to select the native and both soak prerequisites
without requiring remote source publication. Independent remote Git source lanes
remain separate gates. Nothing in these runners pushes Git refs or publishes Hex
packages; official publication and final official reruns remain owner-authorized.

The original `frame_bytes` ceiling remains 65,536 decoded payload bytes. The
additional `wire_frame_bytes` ceiling is 65,584: that same payload plus the fixed
48-byte MEX1 envelope. Both are measured independently; the payload baseline is
not widened. Pending frames/bytes, spool and journal-record limits are unchanged.

The ecosystem subprocess owner uses an explicit 5,400-second aggregate wall-time
budget for native and full-soak gates, including cold dependency builds, service
startup and their sequential bounded checks. Other gates retain 2,400 seconds.
Owner EOF still cancels the child process group. These orchestration budgets do
not alter capture duration, startup/lag policy, authority deadlines or acceptance
thresholds. The actual timeout and cancellation regression suite is
`med_ex/test/qualification_command_test.py`.

An explicit ecosystem `--gate` validates only the repositories participating in
that gate and its prerequisites. Native/soak selection needs the two medical
repositories. Sibling Weld CI is an explicit separate gate. Installed Weld
composition still uses the private MedEx maintainer project.


## Fast source proof and resumable local candidates

Bootstrap once with `mix setup` in each repository. Resolve only genuine lock
entries, review the diffs, and use `mix setup --locked` for the default release
context. The SDK source root adds Blitz `0.5.0`; its existing lock must be
resolved by real Mix/Hex. Fabric's removed coordinator Dialyxir entry can be
pruned only through genuine dependency resolution. Private project locks and
the official smoke fixture must never be hand-written or copied from a different
registry context.

For day-to-day development, run `mix test` from either repository root, or
select a single project with `mix test --project PROJECT`. From the SDK root,
`build_support/qualify_ecosystem.sh fast --no-cache` runs ordinary source tests
in both repositories. `dev` selects repositories changed against `--base`
(default HEAD); SDK changes also select Fabric. These commands do not resolve
consumer projections, build production releases, run Dialyzer/docs or start the
native qualification services. Their separate `medex-tests` and `fabric-tests`
receipts cannot satisfy `medex-core` or `fabric-projects`. Use `--no-cache` to
measure actual execution rather than receipt reuse. Fast/dev permit the explicit
development source selector; release gates refuse it. The SDK's explicit
`build_support/check_consumers.sh --affected BASE` remains a consumer-proof
command, not a fast development test command.

`medex-core` and `fabric-projects` still execute `mix quality --release` and
`medex-short` and `fabric-short` still run independent Python/C/Node checks.
Default full includes all four release gates. The checks-only dispatcher never
bootstraps or repeats root quality. Retain independent passing results unless
their source, tool or input identity changes. Do not claim a source-path result
proves registry installation.

`plan` now shows the local consumer graph. Default `full`/`resume` exclude
`weld-ci`, `weld-minimum`, `medex-remote` and `fabric-remote`. Those remain explicit
`--gate` scopes; using released Weld 0.20.3 never requires a sibling Weld CI run.
Local source lanes cover direct/live/full/prepared/signed registry; remote Git
lanes require their own gate and real remote equality. No remote success is
inferred from local candidates. Gate execution stays sequential across mutable
candidate/native/soak state, while source projects use Blitz resource-aware admission.
Independent failures are collected, descendants are blocked, matching receipts
reuse exact output hashes, and superseded attempts remain under `attempts/`.

The short Python/C/Node checks in `build_support/qualify_projects.sh sdk|fabric`
are additional dispatcher/native/browser tooling proofs. It then invokes the
same canonical root matrix; `--fast` permits intentional source selection, while
the default uses locked dependencies and production compile. Do not run it after
an unchanged passing root matrix simply to duplicate that matrix. Retain its
independent passing test results and rerun only changed checks.

Set `MEDEX_RECEIPT_VECTORS` to an absolute regular-file copy from the frozen SDK
revision. `build_support/receipt_fixture.sh` verifies 51 vectors and SHA-256
`00e4b87285b26e995f5f0e3bff01c3cce5a8f3c4701e41d9f3981b73a197901b` before
source/preparation/native tests. It is a verification input, not runtime data.
Fabric preparation uses `build_support/prepare_qualification.sh SDK_ABSOLUTE
NEW_PRIVATE_EVIDENCE_DIR`, with upstream exact archives already served by the
existing signed candidate registry. It uses the released SDK maintainer tool.
`ops/qc_native.sh --preflight --suite all --artifacts MANIFEST` checks current
tools, PostgreSQL18, pinned Opus/HAPI, Chromium, fixtures and actual archive/registry
identities without starting services. Soak preflight also needs `--volume` on
owned writable ext4. Use the actual absolute paths prepared for that run.
Inspect ignored scratch paths before snapshotting; preserve the installed asset
integrity checks and symlink-refusal tests. No cleanup may remove owner evidence.

### Documentation and official smoke limits

Direct ExDoc groups include DeliveryWorker and Preview Capability/Timeline.
The supplied Weld 0.20.3 schema evidence does not support `groups_for_modules`
for projected `mf_exam`; no unsupported manifest key or new Weld release is
introduced. Verify the installed schema/help locally and keep this limitation
explicit if unchanged.

BR-05 remains a post-publication gate: only after separate owner approval and
all six genuine official versions exist, resolve `examples/hex_smoke/mix.lock`
against official Hex, verify exact family versions/bytes/closure, run locked
compile/test and separate role isolation, then commit the genuine fixture lock.
The checked-in smoke lock is not updated by pre-publication candidate construction;
pre-publication combined proof resolves its own detached lock.
The combined fixture is a resolver/install check, never a production topology.
