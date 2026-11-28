# Executable independent consumers

- [Six-package installed smoke](hex_smoke/README.md): exact release candidates,
  browser asset ownership, synthetic PLX and real Opus/RTP delivery.
- [Independent clinical core](clinical_core/README.md): private source boundary
  consumer with two explicit database handles, native decisions and outbox,
  independent mapping, actual FHIR delivery and exact reconciliation.

Neither consumer is a published package. Production workflow examples live in
[the browser guide](../guides/browser_to_record.md),
[the native lab guide](../guides/handheld_demo.md) and
[release qualification](../guides/releasing_exam.md).

**License:** [MIT](../LICENSE).
