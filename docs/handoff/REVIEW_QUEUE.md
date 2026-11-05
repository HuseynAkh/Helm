<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Opus / Fable review queue — F22

Read this list first after 22:00 Toronto, 2026-11-04. Time alone does not approve
a draft. Opus reviews compile correctness and behavior preservation; Fable/Mac
validation must use assigned ownership and approved local fixtures. Nothing here
authorizes sending, deletion, sharing changes, paid work, publishing or commits.

## First reading list (complete prereview queue)

1. Findings: [P1](../prereview/P1.md), [P2](../prereview/P2.md), [P3](../prereview/P3.md), [P4](../prereview/P4.md), [P5](../prereview/P5.md), [P6](../prereview/P6.md), [P7](../prereview/P7.md), [P8](../prereview/P8.md), [P9](../prereview/P9.md), [P10](../prereview/P10.md), [P11](../prereview/P11.md), [P12](../prereview/P12.md), [P13](../prereview/P13.md), [P14](../prereview/P14.md), [P15](../prereview/P15.md), [P16](../prereview/P16.md), [P17](../prereview/P17.md), [P18](../prereview/P18.md), [P19](../prereview/P19.md), [R1](../prereview/R1.md).
2. Fix dispositions: [fixes-F1](../prereview/fixes-F1.md), [fixes-F2](../prereview/fixes-F2.md), [fixes-F3](../prereview/fixes-F3.md), [fixes-F4](../prereview/fixes-F4.md), [fixes-F5](../prereview/fixes-F5.md), [fixes-F6](../prereview/fixes-F6.md), [fixes-F7](../prereview/fixes-F7.md), [fixes-F8](../prereview/fixes-F8.md), [fixes-F9](../prereview/fixes-F9.md), [fixes-F10](../prereview/fixes-F10.md), [fixes-F11](../prereview/fixes-F11.md), [fixes-F12](../prereview/fixes-F12.md), [fixes-F13](../prereview/fixes-F13.md), [fixes-F14](../prereview/fixes-F14.md), [fixes-F15](../prereview/fixes-F15.md), [fixes-F16](../prereview/fixes-F16.md), [fixes-F17](../prereview/fixes-F17.md), [fixes-F18](../prereview/fixes-F18.md).
3. Wave 23 reports: [fixes-F19](../prereview/fixes-F19.md) (P16/history), [fixes-F20](../prereview/fixes-F20.md) (P17/sessions), [fixes-F21](../prereview/fixes-F21.md) (P18/value policies). These concurrent owner reports are now present; consume their final verification before acceptance. F22 does not certify their completed source changes.
4. [F22 documentation disposition](../prereview/fixes-F22.md), [verification](VERIFICATION.md), [Mac inventory and staged validation](MAC_HANDOFF.md), [contract decisions](CONTRACT_INTEGRATION.md).

## Review order and unresolved gates

- Reconcile each original finding with its fix report and current code; a passing suite is not a finding disposition. F13–F18 supersede earlier ownership/cancellation, monitor, criteria-only search and contents-size reports as described in the inventory. P16–P18 remain review obligations even after F19–F21 land.
- Inspect architecture review Fixes 1/5/8/9, then public contracts, operation evidence and native mutation refusal, session identity/lifetime, monitor recovery, and host composition. Read the local plan at `/workspace/forge/helm-plan/docs/rebuild/01-architecture.md` with `review-01-architecture.md` winning conflicts; use `00-current-state.md` and `00b-opus-review.md` for behavior. Do not fetch shared memory over the network.
- Follow the staged Mac target instructions in MAC_HANDOFF before SDK compilation. Native host, conditional mutation receipts, safe redo, search envelope projection, Inspector saves, cloud/share execution, spring commit routing and gallery rendering remain deferred. Check the final owner reports for narrower residual issues.
- P14-5 producer snapshot-build/100k geometric-bound instrumentation remains explicitly deferred by F18; event counts alone do not prove bounded construction. Linux tests, syntax parsing and citation coverage close no Mac acceptance gate.
