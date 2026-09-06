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

## Runtime validation target

`tests/resilience/test-v6-controlled-recovery.sh` validates:

- creation of a genuine pre-rail `UNKNOWN` by stopping Wero/EPI;
- rail row count = 0 and settlement ledger count = 0 before recovery;
- Wero/EPI recovery and a reconciliation result `NOT_FOUND -> UNKNOWN`;
- invalid/missing explicit confirmation cannot reach the rail;
- valid controlled recovery performs the `NOT_FOUND` preflight and reaches `SETTLED`;
- exactly one logical rail settlement and one settlement ledger row exist;
- recovery Outbox events are emitted once;
- a repeated recovery request after final state is a no-op.

B6 must be validated on CRC before being marked complete.

## Limitations

This POC recovery endpoint is an educational architecture mechanism, not a production payment-operations policy. A production decision would need scheme-specific evidence, reconciliation windows, operational authorization, audit trail, concurrency controls, SLA/RTO rules and potentially human approval. The POC is not affiliated with EPI/Wero or any bank, MayaBanque is fictional, and no real payment data is used.
