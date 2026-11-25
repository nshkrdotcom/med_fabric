# Deployment

`mf_handheld` builds as an ordinary Mix release with no dependency on the
`mf_exam` source tree or database.

## Building a Release

```bash
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix release
```

Copy `_build/prod/rel/mf_handheld` to a target Linux host matching the build
architecture and ABI.

## Runtime Inputs

Provide the following files on the target host with restrictive permissions:

- Device credential JSON issued by `mf_exam` enrollment
- Trusted CA PEM bundle for verifying the `mf_exam` TLS certificate
- Fixture/scenario configuration JSON
- Dedicated writable spool directory on a local filesystem supporting `flock`
  and directory `fsync`

## Running the Release

```bash
bin/mf_handheld eval \
  'Application.ensure_all_started(:mf_handheld); MedExHandheld.CLI.main(["--config", "/etc/handheld/fixture.json", "--scenario", "paired_exam"])'
```
