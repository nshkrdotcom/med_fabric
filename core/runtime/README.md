<p align="center"><img src="assets/runtime.svg" width="200" alt="Encounter supervision and effect dispatch" /></p>

<h1 align="center">Encounter supervision and effect dispatch</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_runtime` is the encounter workflow execution boundary in [Med Fabric](../../README.md). It depends only on [`mf_domain`](../domain/README.md) with zero database or Phoenix dependencies.

---

## What This Owns (and Current Scope)

**Intentionally minimal today**: Currently `MedFabric.Exam`, `MedFabric.ExamWeb.ExamLive`, and `MedFabric.Store.OutboxStore` handle encounter commands and atomic acceptance directly without needing a separate long-lived encounter `GenServer`.

Per the architecture rule—*add a long-lived encounter process only when a workflow needs multi-actor coordination that a supervised request/LiveView + transactional store cannot provide*—`mf_runtime` stays a clean package boundary until durable multi-process encounter recovery or background outbox worker supervision earns its keep.

---

## Commands & Verification

```bash
cd core/runtime
mix test
mix credo --strict
mix dialyzer --force-check
```

## Related Packages

- [Med Fabric Workspace](../../README.md)
- [Domain](../domain/README.md)
- [Store](../store/README.md)
- [Interop](../interop/README.md)
- [Exam App](../../apps/exam/README.md)
