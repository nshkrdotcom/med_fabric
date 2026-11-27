# Deployment

Build `mf_handheld` directly with Mix; it is not a Weld artifact. Its runtime
closure is MedEx plus Gun/OTP TLS. It has no dependency on Exam, private Fabric
components, Opus or RTC. Package-relative code and the CLI run from a relocated
consumer without either source checkout.

Use the pinned supported Elixir/OTP toolchain, a service-owned local spool and
an OS with verified `flock` semantics. Restrict the credential/CA files and root
to the service user. Use explicit approved endpoints, peer/hostname verification
and finite source/byte/session budgets. Monitoring is optional and may be absent.
Do not place an evidence spool under an untrusted writer's directory or allow
multiple writable processes for the same acquisition.

Before the breaking release, inventory old databases, spool/evidence roots and
credential authorities by metadata only. Protect non-disposable state in
approved checksummed offline archives and verify recoverability. Provision a
new namespace for revision 2. A reset or deletion requires explicit operator
approval; the application never performs one.

A coordinated restore compares deployment identity, server journal/index and
manifest inventory, database receipt projection, local ACK/source watermark and
retained coverage. An older server backup can omit bytes already reclaimed by a
device. Account for post-backup acquisitions, decisions and external effects,
including missing newer intent rows. Do not resume writable acquisition when
those facts cannot be established. Preserve and quarantine the affected scope;
if its extent is unknown, keep the deployment non-writable.

Qualify the actual direct package tar, exact dependency locks and source oracle.
Required system lanes include TLS denial, two competing spool owners, lost ACK,
source/ACK/install/deletion crashes, real filesystem exhaustion, monitor kill and
suspension, unknown command/readback, reconnect, and clean 1,740-second ext4 runs
with Preview off and isolated Preview on. Preserve the 15-slot negotiated window,
five-frame source batch, 2,000 ms lag guard and measured queue/reclamation work.
Record outcomes as PASS/FAIL/BLOCKED/NOT RUN with exact artifact identities. A
synthetic source test does not establish clinical or physical-device readiness.
