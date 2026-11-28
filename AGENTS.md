# Engineering

Use Elixir ~> 1.20 and keep the implementation small. Every package, process,
mutable field and abstraction must serve an exercised requirement. Prefer pure
functions, one owner per fact and existing libraries. Delete unused scaffolding,
test guarantees that can fail and report native evidence precisely.

## Quality checks

- README, documentation, and artwork-only edits need only checks relevant to
  the edited files. Skip code test suites, native checks, and release tooling
  unless explicitly requested.
- For code changes, run the checks that cover the affected behavior. For release
  qualification, run the complete source and native lanes, including Preview.
  See guides/releasing_exam.md and build_support/release_matrix.json.
- Report checks blocked by missing services or tooling as NOT RUN. Do not
  publish, reset data, or activate any deployment without explicit authorization.

## Revision 2 architecture

- Exam is the host boundary. Domain is pure clinical policy; Store owns all SQL
  and explicit db/tx operations; Interop maps and sends only after native commit.
- One common acquisition path serves browser microphone and paired waveforms;
  PLX is event-only and manual pulse has immutable native manual evidence.
- Never duplicate SDK receipt/cursor rules or add another recorder. A durable
  ACK is historical evidence, not new authority; bind each response to the exact
  connection incarnation. Unknown effects require retirement and recovery.
- Hold the per-stream effect gate before SQL scope; wait for actual OS/storage
  quiescence before successor, terminal reconciliation or manifest promotion.
- Clinical decisions, native observations and delivery intents commit atomically
  without FHIR mapping/configuration. Pin identity/resource/destination before
  dispatch; enforce distinct safe-repeat and safe-confirmation predicates.
- Fresh revision-2 schema/root/spool only. Preserve immutable deployment UUID.
  Restored snapshots require accounting for later irreversible effects.
- One authoritative capture service owns the service filesystem and OS root lock.
  No simultaneous writable clones, distributed failover or automatic reset.
- Optional Preview runs separately, with concrete Opus/RTC and bounded viewing
  authority; raw acquisition does not depend on media. Direct talkback uses
  cooperating-client renewal and cannot enforce server-side P2P termination.
- Only mf_exam is composed by Weld, with Domain/Store/Interop. Handheld and Preview
  are direct Mix packages. Exactly six public packages across both repositories.
- .mix_sources.json is the sole development selector; internal core paths stay
  fixed. Published archives resolve normal bounded Hex dependencies.
