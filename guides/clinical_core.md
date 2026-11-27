# Private clinical core and explicit hosts

Domain, Store and Interop are private source components, composed into mf_exam.
They are also exercised by an independent, unpublished fixture host. A reusable
core operation receives an explicit DB/transaction or explicit destination;
there is no hidden globally named Exam pool or UI dependency.

Domain accepts verified native evidence and explicit actor/time. It validates
choice, contiguous sample selections/epoch, acknowledged defects, eligible events
and exact native decimal values. Selected values are nonnegative; only SpO2 has
the supported lab upper bound 100. Zero is permitted and pulse above 100 is not
rejected solely by that limit. Preserve raw SFLOAT bits, special indicators,
status and time provenance. No float reinterpretation or extra clinical threshold.

Store accepts one native plan atomically. The stable client request key is scoped
to encounter and authenticated actor; canonical request content excludes newly
generated commit time. Exact committed replay is an authorized read even after
closure. Changed content or competing decisions conflict. A repeat allocates one
new child acquisition, and replay returns the same child. Manual evidence uses
an explicit immutable row; SQL enforces XOR/composite encounter/source references.

Valid export-intended observations get one stable intent each even without export
configuration. FHIR mapping happens only afterward. The external identifier
system is urn:uuid:<deployment UUID>, with stable native observation ID as value.
Store persists pins and attempt state; Interop performs no clinical mutation.
No generic repository, duplicate acceptance route or fake waveform observation.
