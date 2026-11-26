# Release the Exam package

The checked-in manifest at `build_support/weld.exs` declares one release
artifact, `mf_exam`. Weld composes Exam, Domain, Interop, and Store into one
Mix application with Exam's static files and Store's migrations under `priv/`.
It reads the package version from `apps/exam/VERSION`. The ordinary workspace
and the separate Handheld and Preview projects keep their own Mix workflows.

From the repository root, use a Hex environment that resolves the
exact MedEx 0.3.1 archive recorded by the candidate lock. Use the private
signed registry for local verification before the base is public.

```sh
cd tools/maintainer
mix deps.get --check-locked
mix release.status
mix weld.verify --artifact mf_exam
```

From a clean Git checkout, run `mix release.prepare --artifact mf_exam` and
then `mix release.status --artifact mf_exam`. Use the full bundle identity
and default tag from the output in the commands below. Run the dry run before
pushing the release tag.

```sh
mix release.publish --artifact mf_exam --identity "$identity" --dry-run
mix release.track --artifact mf_exam --identity "$identity" --tag-release --push
mix release.verify_tag "$tag"
mix release.publish --artifact mf_exam --identity "$identity" --tag "$tag"
mix release.archive --artifact mf_exam --identity "$identity"
```

Before publication, extract the prepared Hex archive into a disposable directory,
assemble the release using the runtime-config overlay described in the
[Exam package guide](../apps/exam/guides/getting_started.md), and boot it
against fresh PostgreSQL. Confirm that migrations 006 and 007 are present
and applied, then exercise paired and spot-check acquisition with the
packaged clients. The archive carries the runtime sources. The Mix
assembler's default runtime config copy carries only the entry file.

Run archive after Hex confirms publication. Prepared bundles and writable
publish workspaces live under the checkout's ignored `.weld/` directory.
The `projection/mf_exam` commit and annotated tag preserve the Git receipt
for the same bundle identity.

## Restore paired evidence and database state

Quiesce Exam capture and outbox delivery before taking a coordinated
`pg_dump` and copying the artifact root. Record the source versions and the
database dump and manifest digests. Restore the dump into a fresh database,
copy the artifact root to a separate writable volume owned by the service
user, and configure the restored instance with those two paths. Keep the
original database and volume available until verification succeeds.

Confirm that a previously accepted revision opens at its recorded digest and
that a verified segment still resolves to its documented sample coordinates.
For a pending delivery with a known prior remote write, verify retry against
the same qualified destination and confirm it resolves to the original
remote observation. In a disposable restore copy, omit one required object
and confirm that review refuses the manifest. Keep delivery disabled during
restore except for the explicitly selected retry check.
