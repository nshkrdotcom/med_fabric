# Architecture refinement

The connected exam consumes one projected MedEx SDK. MedEx owns live peer state and measured capture facts. The exam translates those facts into commands for the pure encounter domain. Med Fabric owns review and acceptance. Both repositories keep their child Mix projects while their dependency and test boundaries are evaluated.

| State | Authority | Recovery |
| --- | --- | --- |
| Peer connection and current preview | MedEx session process and transport | Rejoin with a new connection ID. Discard late events from a replaced connection. |
| Recording identity and measured continuity | Capture producer | Redelivery preserves the original digest. The session reducer treats a conflicting digest as unresolved. |
| Requested acquisition, review candidate and acceptance | Fabric encounter domain | The executable model is pure. Durable recovery remains an implementation milestone. |
| Projection source identity | MedEx projection refresh | Check the recorded input against current sources before local consumer verification. |

## Checkpoints

- [ ] Verify source tests, SDK projection and exam dependency identity.
- [ ] Correct ownership bugs in the existing MedEx reducer. Exercise late disconnects and redelivery after conflict. Remove duplicated integrity state.
- [ ] Use one SDK constructor in the exam. Prove the capture fact can create one review candidate without coupling the domain to SDK modules.
- [ ] Verify SDK source and projection, then pin the verified projection in the exam. Check the exam against pinned Git and the local projection.
- [ ] Prove actual browser media, including a reconnect during simulated capture. Revisit the process and package graph using the resulting trace.

The current session coordinator serializes pure transitions and dispatches effects to subscribers. Keep one coordinator until capture has an independently demonstrated failure or ownership boundary. Leave the Fabric runtime passive until a commit and retry path gives it concrete execution behavior. Add database and FHIR implementation in separate increments after the browser and composition review.
