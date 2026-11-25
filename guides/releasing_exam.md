# Release the Exam package

The checked-in manifest at `build_support/weld.exs` declares one release
artifact, `mf_exam`. Weld composes Exam, Domain, Interop, and Store into one
Mix application with Exam's static files and Store's migrations under `priv/`.
It reads the package version from `apps/exam/VERSION`. The ordinary workspace
and the separate Handheld and Preview projects keep their own Mix workflows.

From the repository root:

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

Run archive after Hex confirms publication. Prepared bundles and writable
publish workspaces live under the checkout's ignored `.weld/` directory.
The `projection/mf_exam` commit and annotated tag preserve the Git receipt
for the same bundle identity.
