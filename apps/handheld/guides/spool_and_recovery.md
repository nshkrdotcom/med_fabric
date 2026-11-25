# Spool & Recovery

`mf_handheld` is designed so that network outages between the handheld device
and `mf_exam` do not lose committed clinical acquisitions.

## Durability Boundary

1. Synthetic peripheral frames and measurement events are written into the
   bounded local spool (`MedExHandheld.Spool`) and flushed with directory
   `fsync` under an exclusive `flock` lock.
2. The measurement durability guarantee begins once the handheld command
   journal has synced to local disk.
3. `MedExHandheld.Transport` opens an authenticated Gun WSS/TLS connection to
   `mf_exam` and streams records with explicit acknowledgement tracking.

## Disconnect & Replay

When the uplink drops:

- Active acquisition continues writing into the bounded disk spool.
- On reconnect, `MedExHandheld.Session` resumes from the last server-confirmed
  offset.
- `mf_exam` deduplicates replayed segments and events by acquisition ID and
  sequence range, preserving exact source hashes.

## Software Monitor Separation

Live monitor audio (`MedExHandheld.Monitor`) uses a separate credit-paced WSS
connection. It retains only the single latest 20 ms frame and discards frames
older than 200 ms locally—monitor congestion never blocks authoritative spool
writes or replay.
