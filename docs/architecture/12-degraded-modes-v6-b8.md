# V6 B8 — Degraded modes matrix

## Purpose

B8 consolidates the degraded-mode behavior of the V6 CRC lab. It does not introduce production HA claims. The goal is to make each dependency outage explicit in terms of availability, business state, retry policy, reconciliation, observed recovery and duplication risk.

B8 reuses runtime evidence already validated in B1, B2, B3 and B5, and adds the two full-outage cases that were still missing: SCT Inst and API Gateway.

## Runtime evidence sources

| Dependency outage | Evidence |
|---|---|
| PostgreSQL | `tests/resilience/test-v6-postgresql-recovery.sh` — B1 |
| Kafka/Redpanda | `tests/resilience/test-v6-kafka-outbox-recovery.sh` — B2 |
| Keycloak | `tests/resilience/test-v6-keycloak-recovery.sh` — B3 |
| Wero/EPI | `tests/resilience/test-v6-wero-outage-unknown.sh` — B5 |
| SCT Inst | `tests/resilience/test-v6-degraded-modes.sh` — B8-SCT |
| API Gateway | `tests/resilience/test-v6-degraded-modes.sh` — B8-GW |

## Degraded-mode matrix

| Failure | Service available? | Creation policy | Read policy | Business state during outage | Retry policy | Reconciliation | Observed recovery evidence | Duplication risk / control |
|---|---|---|---|---|---|---|---|---|
| Wero/EPI unavailable | Gateway and local payment service remain reachable | Authorized request is accepted conservatively as `UNKNOWN` when Wero cannot be reached | Existing local payment remains readable | `UNKNOWN`; no SCT Inst row; no settlement ledger | No blind replay, including same idempotency key after Wero returns | Required; B5 observed `NOT_FOUND -> UNKNOWN`; B6/B7 define explicit controlled recovery | Wero recovery observed **11 s** | Controlled by idempotency plus explicit recovery gates |
| SCT Inst unavailable | Gateway, Payment Service, Consumer PSP and Wero remain reachable | Expected B8 behavior: payment becomes `UNKNOWN` because final rail outcome cannot be obtained | Local payment remains readable | Expected: `UNKNOWN`; no rail row; no settlement ledger | No blind replay | After SCT Inst recovery, fresh status must be checked before any explicit recovery | Runtime measurement pending B8 | Controlled by idempotency, `NOT_FOUND` preflight and atomic recovery claim |
| PostgreSQL unavailable | Stateful payment operations depending on DB are unavailable until DB recovers | Creation cannot be safely completed while persistence is unavailable | Reads requiring DB are unavailable | No valid new business state should be inferred without durable persistence | Client retry only after DB recovery; no assumption that an uncommitted request succeeded | Use durable DB state after recovery | B1: Ready + SQL recovery **36 s**, same PVC, selected rows lost = 0 | Persistence boundary prevents claiming success without DB commit; B1 is not PostgreSQL HA |
| Kafka/Redpanda unavailable | Synchronous payment path remains available | Creation/settlement may complete because DB + Outbox are authoritative | Payment reads remain available; audit stream is delayed | Payment can be `SETTLED`; Outbox remains pending | Outbox publisher retries; clients do not replay the business payment to fix Kafka | Event audit catches up after broker recovery | B2: backlog **3**, drain **3/3 in 7 s** | Transactional Outbox + event-id deduplication prevent business duplication |
| Keycloak unavailable | Already-issued JWT can remain usable for a bounded period; new authentication unavailable | Existing valid JWT can authorize according to cached verification; no new token can be obtained | Existing valid JWT can continue until token/JWK conditions no longer permit it | Business state is unchanged by IAM outage itself | Do not bypass IAM; wait for token service recovery when a new token is required | Not a payment reconciliation problem | B3: token recovery **131 s**, fresh JWT/JWK authorization **135 s** | Security control is fail-closed for new authentication; this is not Keycloak HA |
| API Gateway unavailable | Public payment API is unavailable | Creation must not reach backend through the public path | Public reads are unavailable | No new payment row should be created by a request that never reaches the backend | Retry the untouched client intent after gateway recovery | Not required if the request never entered the payment system | Runtime measurement pending B8 | V3B backend isolation plus idempotency prevent bypass/duplicate execution |

## B8 runtime target

`tests/resilience/test-v6-degraded-modes.sh` must validate the two remaining full-outage cases.

### SCT Inst full outage

Expected sequence:

```text
SCT Inst replicas 2 -> 0
payment request
-> UNKNOWN
rail rows = 0
settlement ledger = 0
same idempotency key -> no blind replay
SCT Inst restored
reconcile -> NOT_FOUND / UNKNOWN
explicit controlled recovery
-> SETTLED
rail rows = 1
settlement ledger = 1
```

### API Gateway full outage

Expected sequence:

```text
API Gateway replicas 2 -> 0
public read unavailable
public create unavailable
payment row = 0
rail row = 0
ledger row = 0
API Gateway restored
retry untouched authorized intent
-> SETTLED exactly once
```

Both outage experiments temporarily suspend Argo CD self-heal only to inject the failure. Desired replicas are restored and self-heal is re-enabled before the phase can pass.

## Completion rule

B8 is not complete until the runtime test finishes with:

```text
V6 OK (phase B8)
```

After that result, the measured SCT Inst and API Gateway recovery times must replace the pending values in this document, and the final V4/V5/V6 regression must be run before V6 CRC is declared complete.

## CRC limitation

OpenShift Local / CRC is single-node. This matrix describes controlled service/pod outages in the lab. It does not validate worker-node HA, zone HA, site HA, production database HA, multi-broker Kafka HA, clustered Keycloak, PRA or production RPO/RTO targets.
