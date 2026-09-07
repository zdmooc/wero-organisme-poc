# V6 B7 — Concurrent controlled recovery and idempotence

## Purpose

B7 validates that the explicit B6 recovery mechanism remains safe when several recovery requests arrive at the same time for the same pre-rail `UNKNOWN` payment.

The goal is not sequential idempotence. The test must prove concurrent exclusion across the two `payment-service` replicas running on CRC.

## Preconditions inherited from B5/B6

The tested payment starts in this state:

```text
payment = UNKNOWN
SCT Inst rail rows = 0
settlement ledger rows = 0
fresh rail preflight = NOT_FOUND
```

The payment was created while Wero/EPI was unavailable, then Wero/EPI recovered. No blind replay occurred before B7.

## Concurrency mechanism

The B6 recovery endpoint performs a conditional database claim:

```text
UNKNOWN -> RECOVERY_PENDING
```

The update is conditional on the current database status still being `UNKNOWN`.

Only the caller whose update affects exactly one row owns the controlled resubmission. Other concurrent callers either:

- observe `RECOVERY_PENDING` and return `RECOVERY_ALREADY_IN_PROGRESS`;
- lose the conditional claim and return `RECOVERY_ALREADY_CLAIMED`;
- or, if they arrive after completion, return `ALREADY_FINAL`.

No losing caller is allowed to resubmit to the rail.

## Runtime test

Test:

```text
tests/resilience/test-v6-concurrent-recovery.sh
```

The test launched **8 simultaneous recovery requests** against the same `paymentId` through the API Gateway.

Observed actions:

```text
total = 8
RESUBMITTED = 1
RECOVERY_ALREADY_CLAIMED = 1
RECOVERY_ALREADY_IN_PROGRESS = 6
ALREADY_FINAL = 0
```

Exactly one caller therefore owned the recovery claim and resubmitted the stored payment intent.

## Business invariants after concurrency

Final state:

```text
payment status = SETTLED
SCT Inst rail rows = 1
settlement ledger rows = 1
PAYMENT_RECOVERY_STARTED = 1
PAYMENT_RECOVERED = 1
PAYMENT_SETTLED = 1
PAYMENT_RECOVERY_FAILED = 0
```

The result finished with:

```text
V6 OK (phase B7)
```

This proves concurrent database-claim exclusion and business idempotence for this CRC lab scenario.

## What B7 proves

B7 proves that multiple simultaneous recovery requests for one payment do not cause:

- multiple controlled resubmissions;
- duplicate SCT Inst settlements;
- duplicate settlement ledger entries;
- duplicate recovery-start events;
- duplicate recovered events.

The important property is ownership of the recovery action, not merely duplicate suppression after the fact.

## What B7 does not prove

CRC is single-node. B7 does **not** prove:

- worker-node HA;
- zone HA;
- site HA;
- multi-site split-brain handling;
- production PostgreSQL HA semantics;
- production RPO=0;
- correctness under a database network partition.

Those remain production architecture topics in Phase C.

## Relationship to B8

After B7, the only remaining Phase B item before V6 CRC closure is B8: formalized degraded-mode behavior for Wero/EPI, SCT Inst, PostgreSQL, Kafka, Keycloak and API Gateway.
