# Med Fabric Handheld

`mf_handheld` 0.3.0 is a direct Mix package for a reference device producer,
its durable local spool, authenticated TLS upload, and disposable local monitor.
It depends on `med_ex ~> 0.4.0` and Gun. Run the reference paired acoustic/ECG
profile or the PLXS spot-check profile with an explicitly configured Exam host.
The reference sources demonstrate software behavior; they provide no physical
device calibration or clinical qualification.

## Ownership

`MedFabric.Handheld.Session` coordinates admission, reconnect and final drain.
`MedFabric.Handheld.Paired` produces source records and uploads retained bytes.
`MedFabric.Handheld.Spool` owns local durability and its single OS `flock`.
`MedEx.Receipt`, `MedEx.StreamCursor` and `MedEx.Wire.Credit` own technical
receipt, progression and credit rules. `MedFabric.Handheld.Monitor` owns a separate,
bounded derived gain ledger and the latest disposable batch. Preview, codecs,
RTC, clinical decisions and database access do not belong in this package.

## Run

Add the package to a consumer:

```elixir
{:mf_handheld, "~> 0.3.0"}
```

Start the consumer applications and invoke the packaged CLI:

```sh
mix run -e 'MedFabric.Handheld.CLI.main(System.argv())' -- \
  --config /etc/med_fabric/handheld.json --scenario paired_exam
```

The second scenario is `plx_spot_check`. The JSON configuration identifies an
approved `wss://` server, absolute credential/CA paths, device, encounter,
acquisition and an absolute new spool root. See [Getting started](guides/getting_started.md).
TLS certificate and hostname verification remain enabled. A local source starts
only after authenticated revision-2 admission. The credential is never written
to reports or evidence.

## Durable boundaries

A source batch contains at most five records. Each record is checksum verified,
file synced and immutably installed before the source cursor advances. Audio is
offered to the optional monitor only after the raw spool operation succeeds.
A network connection permits up to 15 outstanding source records and 262,144
encoded bytes; gaps consume both slot and byte credit. Volatile `accepted`
messages release neither spool records nor credit.

An authenticated `durable` reply carries the complete connection binding and a
nested canonical receipt. The SDK checks identity/progression; the spool proves
actual retained coverage, persists the receipt, then deletes exactly the covered
records. A replaced or locally invalidated connection cannot update recovery
state. A historical committed ACK can prove earlier durability while its local
binding remains active; it never renews current authority.

Stop drains the final short source batch, checkpoints before waiting for durable
coverage, then verifies the authenticated terminal receipt/index identity and
requests acquisition finalization. A process restart interrupts at the recovered
local tail; it does not regenerate an unobserved interval. See [Spool and recovery](guides/spool_and_recovery.md).

## Package verification

Run `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`
and `mix docs --warnings-as-errors` with the pinned toolchain. The test corpus
uses the exact shared MedEx receipt vector file; detached qualification supplies
`MEDEX_RECEIPT_VECTORS` with its SHA-256 verified by the test. Real TLS/Exam,
PostgreSQL, filesystem-full and 1,740-second source-oracle lanes are separate
required system gates; unit tests do not establish those results.
