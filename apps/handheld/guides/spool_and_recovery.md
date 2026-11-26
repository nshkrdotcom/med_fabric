# Spool & Recovery

`mf_handheld` is designed so that network outages between the handheld device
and `mf_exam` do not lose committed clinical acquisitions.

## Durability Boundary

1. Handheld syncs synthetic waveform frames and measurement events with
   directory sync in a bounded local spool under an exclusive `flock` lock.
   For 50 Hz audio capture, up to 5 frames (100 ms) are held in memory and
   staged together before atomic rename and directory sync (flushing
   immediately on gaps, stop, or completion); uncommitted temp files left by
   a hard crash are discarded on restart.
2. The authenticated WSS connection can pipeline up to 15 waveform records
   per stream with Exam 0.1.1. The single-credit mode remains available for
   peers that do not negotiate a larger window.
3. An accepted receipt can cover frames still in Exam memory. Handheld
   persists a verified durable receipt before reclaiming its covered
   waveform prefix. Measurement events use their own durable acknowledgment
   and sealed inventory.

## Disconnect & Replay

When the uplink drops:

- Active acquisition continues writing into the bounded disk spool.
- On reconnect, `MedExHandheld.Session` resumes from the verified server
  durable boundary and replays retained records after it.
- `mf_exam` deduplicates replayed segments and events by acquisition ID and
  sequence range, preserving exact source hashes.

## Software Monitor Separation

Live monitor audio (`MedExHandheld.Monitor`) uses a separate credit-paced WSS
connection. It retains only the single latest 20 ms frame and discards frames
older than 200 ms locally—monitor congestion never blocks authoritative spool
writes or replay.
