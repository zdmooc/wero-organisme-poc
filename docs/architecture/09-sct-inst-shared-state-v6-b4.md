# V6 B4 — SCT Inst shared state and pod failover

## Objective

Remove the functional SPOF discovered in phase A: `mock-sct-inst` previously stored settlement results in process memory, so two replicas could disagree about the same payment.

## Design change

The settlement state is externalized to PostgreSQL in table `sct_inst_transfers`.

Each row is keyed by `payment_id` and stores:

- `status`;
- `settlement_id`;
- `created_at`.

Settlement creation uses `INSERT ... ON CONFLICT (payment_id) DO NOTHING`, then reads the shared row back. This preserves one rail settlement identity even if the same payment is observed again by another pod.

`mock-sct-inst` now runs with:

- 2 replicas;
- `PodDisruptionBudget` `minAvailable: 1`;
- the same PostgreSQL credentials delivered from the existing OpenShift Secret;
- no process-local settlement map.

## Runtime validation

Test: `tests/resilience/test-v6-sct-inst-shared-state.sh`.

The CRC run completed with `V6 OK (phase B4)`.

Observed sequence:

1. a new payment was intentionally executed with `TIMEOUT_AFTER_SETTLEMENT`;
2. the rail committed `SETTLED` in the shared PostgreSQL store while Payment Service recorded local state `UNKNOWN`;
3. the original SCT Inst POST was handled by pod `mock-sct-inst-c74ff5ddd-hfpr6`;
4. that exact pod was deleted;
5. reconciliation was served by the different surviving pod `mock-sct-inst-c74ff5ddd-h2llp`;
6. the shared rail status was `SETTLED`;
7. the reconciliation reused the exact same settlement id `SCT-d574e3e7-9305-40bc-a7de-f4261c32b9a8`;
8. the local payment moved `UNKNOWN -> SETTLED`;
9. the shared rail row remained unique;
10. the settlement ledger entry remained unique;
11. `mock-sct-inst` recovered to two ready replicas;
12. the complete V4/V5 business and observability regression passed afterward.

## What B4 proves

B4 proves pod-level failover semantics for the SCT Inst mock on CRC: the pod that created the settlement can disappear, and another pod can answer the later status/reconciliation request from shared durable state without returning `NOT_FOUND` or creating a second settlement.

## What B4 does not prove

This is not end-to-end production HA:

- PostgreSQL remains a shared mono-instance dependency in this CRC lab;
- CRC remains single-node;
- no node, zone, storage-array or site failure is covered;
- no production RTO/RPO target is established by this test.

The next resilience work should inject an explicit Wero/EPI outage/timeout and verify controlled `UNKNOWN`, recovery, reconciliation and retry/idempotence behavior without blind payment replay.
