# Independent clinical core host

This is a private test consumer, not a seventh release package. It imports only
Domain, Store and Interop, obtains two explicit database handles and executes
manual evidence entry, native review, atomic observation and outbox acceptance,
authorised replay after closure, independent FHIR mapping, pinned dispatch and
exact remote reconciliation. No Exam application, routes, sockets, process names,
recording root or peripheral participates.

Set `MF_CORE_DATABASE_URL_A`, `MF_CORE_DATABASE_URL_B`, two distinct stable
`MF_CORE_DEPLOYMENT_UUID_A` / `MF_CORE_DEPLOYMENT_UUID_B`, `MF_CORE_FHIR_URL`,
`MF_CORE_PATIENT_REF` and `MF_CORE_ENCOUNTER_REF` to dedicated synthetic services.
Both databases must be empty or already have the exact supported revision-2
schema and corresponding deployment identity. No command resets either database.
The referenced Patient and Encounter must already exist in the test FHIR service.

Run from the repository root:

```sh
ops/qualify_core_host.sh
```

The runner assembles an independent directory containing the three private core
components and this consumer, resolves the bounded `med_ex ~> 0.4.0` dependency,
compiles without warnings and runs the tests. Its environment can select the
signed candidate registry during qualification. Preserve the generated lock,
dependency tree, stdout, versions and registry/archive checksums as evidence.
The copied consumer has no runtime checkout-relative access to Exam. The script
retains its evidence directory and never publishes a package.

Database B proves that an unavailable external reference representation blocks
its export intent after native acceptance; a negative pulse is separately
rejected as native invalidity. The broader integration suite additionally tests
multi-metric atomicity, unsupported mapping, concurrency, lost responses and
both safe retry/confirmation predicates. This fixture makes one first dispatch;
it does not assert conditional-create qualification for an arbitrary server.
