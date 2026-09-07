# V6 B5/B6 — Wero outage and controlled UNKNOWN recovery

## Purpose

These phases distinguish two very different `UNKNOWN` situations:

1. the rail may already have accepted the payment, in which case blind replay is unsafe;
2. the payment did not reach the rail, in which case a later resubmission can be considered only through an explicit controlled recovery decision.

The lab therefore keeps `UNKNOWN` conservative by default. Reconciliation may observe the rail, but it does not automatically resubmit a payment.

## B5 — Wero/EPI unavailable before SCT Inst

Runtime validation on CRC finished with `V6 OK (phase B5)`.

Observed scenario:

- both `mock-wero` replicas were stopped under a controlled Argo self-heal suspension;
- an already-authorized payment was submitted;
- Payment Service persisted `UNKNOWN`;
- shared SCT Inst state contained **0 rows** for that payment;
- settlement ledger contained **0 rows**;
- Outbox contained `PAYMENT_CREATED`, `PAYMENT_PROCESSING`, `PAYMENT_UNKNOWN`;
- replay with the same idempotency key during the outage did not create a rail settlement;
- `mock-wero` recovered to two replicas and Argo CD returned to `Synced/Healthy` in **11 s**;
- replay with the same idempotency key after recovery still did not resend the payment;
- reconciliation returned `railStatus=NOT_FOUND` and preserved local `UNKNOWN`;
- the complete V4/V5 business and observability regression passed afterward.

This validates the safe default: **do not infer failure and do not automatically resend an `UNKNOWN` payment**.

## Why `NOT_FOUND` does not automatically mean retry

A rail status query returning `NOT_FOUND` is evidence, not universal proof that no previous request can still settle. Real external systems can have propagation delay, asynchronous processing or temporary status inconsistency.

For that reason B6 does not turn reconciliation into an automatic retry engine.

## B6 — explicit controlled recovery

B6 adds a separate recovery operation for the specific lab case where an operator has decided to resubmit after confirming the pre-rail scenario.

Endpoint:

```text
POST /api/payments/{paymentId}/recover
role: payment-reconcile
body: {"confirmation":"RESUBMIT_AFTER_RAIL_NOT_FOUND"}
```

The recovery contract is intentionally stricter than an ordinary retry:

1. explicit confirmation is mandatory;
2. the local payment must still be `UNKNOWN`;
3. Payment Service performs a fresh SCT Inst status preflight outside JTA;
4. if the rail says `SETTLED` or `FAILED`, reconciliation wins and **no resubmission occurs**;
5. if the rail is unavailable or not final, recovery waits;
6. only `NOT_FOUND` allows the recovery path to continue;
7. a conditional database update atomically claims `UNKNOWN -> RECOVERY_PENDING` so only one N+1 Payment Service replica can own the resubmission;
8. the stored payment intent is resubmitted once;
9. final state, ledger and Outbox are persisted atomically after the remote call;
10. a later recovery request against a final payment is a no-op.

New Outbox evidence:

- `PAYMENT_RECOVERY_STARTED`
- `PAYMENT_RECOVERED` when the controlled resubmission reaches a known downstream result
- `PAYMENT_RECOVERY_FAILED` if the recovery attempt again becomes uncertain

## State sketch

```text
UNKNOWN
  |
  | explicit confirmation
  v
fresh SCT Inst status preflight
  |
  +-- SETTLED/FAILED --> reconcile only, no resend
  |
  +-- unavailable/other --> stay UNKNOWN
  |
  `-- NOT_FOUND
        |
        v
atomic claim UNKNOWN -> RECOVERY_PENDING
        |
        v
single controlled resubmission
        |
        +-- SETTLED --> ledger once + final state
        +-- FAILED  --> final failure
        +-- timeout/error --> UNKNOWN again
```

## B6 runtime validation — CRC

`tests/resilience/test-v6-controlled-recovery.sh` passed with `V6 OK (phase B6)`.

Observed evidence:

- the test created a genuine pre-rail `UNKNOWN` while Wero/EPI was stopped;
- before recovery, SCT Inst contained **0** row and settlement ledger contained **0** row for the payment;
- Wero/EPI returned and the initial reconcile answered `railStatus=NOT_FOUND`, `afterStatus=UNKNOWN`;
- invalid recovery confirmation was rejected and still left the rail row count at **0**;
- explicit recovery answered:
  - `railStatusBefore=NOT_FOUND`;
  - `action=RESUBMITTED`;
  - `afterStatus=SETTLED`;
- exactly **1** SCT Inst rail row existed after recovery;
- exactly **1** settlement ledger row existed after recovery;
- Outbox contained exactly **1** `PAYMENT_RECOVERY_STARTED`;
- Outbox contained exactly **1** `PAYMENT_RECOVERED`;
- a repeated recovery request answered `action=ALREADY_FINAL` and did not create a second settlement;
- observed Wero/EPI recovery time was **11 s**.

The runtime evidence therefore validates the B6 sequential controlled-recovery contract on CRC.

It does **not** yet prove the concurrent exclusion property when multiple recovery requests arrive simultaneously against two Payment Service replicas. That proof is B7.

## Next validation — B7 concurrency/idempotence

B7 must issue several simultaneous recovery calls for the same `paymentId` / payment intent and prove:

- only one atomic `UNKNOWN -> RECOVERY_PENDING` claim succeeds;
- only one rail resubmission is executed;
- exactly one rail settlement remains;
- exactly one settlement ledger remains;
- no duplicate recovery/business Outbox is created;
- losing concurrent callers receive a safe no-op/in-progress/final response rather than triggering another rail call.

The purpose is to prove the exclusion mechanism under real concurrency, not merely through sequential retries.

## Limitations

This POC recovery endpoint is an educational architecture mechanism, not a production payment-operations policy. A production decision would need scheme-specific evidence, reconciliation windows, operational authorization, audit trail, concurrency controls, SLA/RTO rules and potentially human approval. The POC is not affiliated with EPI/Wero or any bank, MayaBanque is fictional, and no real payment data is used.

CRC is single-node. B5/B6 do not prove node HA, zone HA, site HA, disaster recovery or a production RPO=0 claim.
