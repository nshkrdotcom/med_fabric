<p align="center"><img src="assets/exam.svg" width="200" alt="Connected remote examination" /></p>

<h1 align="center">Connected remote examination</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_exam` (`apps/exam`) is the connected remote clinical examination application in [Med Fabric](../../README.md). It is the Phoenix + LiveView host app that consumes the single Welded `:med_ex` SDK and wires together `mf_domain`, `mf_store`, and `mf_interop`.

---

## Browser-to-record path

The Phoenix app starts its own endpoint and PubSub. An explicitly enabled local lab uses one synthetic encounter. The browser negotiates a receive-only peer through an authorized channel. The SDK finalizes the fixture recording independently of preview, and the clinician reviews that exact recording. PostgreSQL persists acceptance. A separate action sends the stored observation to HAPI.

See the [native runbook](../../guides/browser_to_record.md) for prerequisites, exact commands, and the listening check.
