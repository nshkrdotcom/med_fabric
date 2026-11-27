# Failure and recovery matrix

| Fault | Required behavior |
|---|---|
| Source record not locally durable | Do not send as recoverable persisted source |
| Accepted-only writer result | Retain source; no ACK-based deletion |
| Known precommit failure | Preserve prefix; bounded retry only under current authority |
| Unknown writer or DB outcome | Retire, quiesce actual effects and recover journal truth |
| PG dies before/after journal sync | Preserve admitted bytes; no ACK for unknown SQL projection |
| Rotation/revoke during in-flight write | No new obsolete admission; settle actual prior effect |
| ACK delayed across replacement | Ignore obsolete incarnation; reconcile under new binding |
| Local ACK persisted before partial delete crash | Resume exact O(k) reclamation idempotently |
| Corrupt chain, index, manifest or spool | Refuse/quarantine, never manufacture repair |
| Terminal index absent | Read-only recovery reports it; authorized exact install only |
| Stage/install/promote interruption | Recover exact staged bytes and digest |
| Physical spool/journal/index/manifest ENOSPC | Preserve verified prefix; truthful unknown/interrupted |
| Browser main-thread stall/page loss | Finite buffers and actual loss/interruption, no fake continuity |
| Native clinical selection invalid | Entire plan aborts with no partial observations/intents |
| Valid selection but mapper/config fails | Native acceptance remains; independent blocked intent |
| Remote response lost or stale HTTP sender | Pinned unresolved; require safe-repeat/confirmation proof |
| One remote match while unsafe send outstanding | Remain unresolved; match alone cannot prove no duplicate |
| Preview/monitor/trace/ETS/provider fault | Raw recording and verified review remain independent |
| Root lock or DB/root UUID mismatch | Refuse or fail-stop writable service |
| Older backup missing later irreversible effects | Account for them or block affected/full namespace |

Run actual barriers and native services for all relevant QA-03/04/05/06 cases.
A return-value mock or source scan alone does not prove fault behavior. Preserve
exact command/status/source/archive identity and durable observations per case.
