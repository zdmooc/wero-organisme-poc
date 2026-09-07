# V6 — SPOF / Chaos / HA / Resilience

## Goal

V6 turns the V5 GitOps deployment into a resilience lab. The objective is not to claim production-grade HA on CRC, but to identify single points of failure, inject controlled failures, measure recovery and progressively remove avoidable SPOFs.

The V5 business invariants remain mandatory after every V6 experiment:

- consent and SCA remain valid;
- payment can reach `SETTLED` when required dependencies are available;
- idempotency prevents duplicate business execution;
- ledger remains coherent;
- transactional outbox preserves events;
- Kafka audit retains `paymentId`, `correlationId` and trace continuity;
- Prometheus, Jaeger and Grafana remain usable;
- Argo CD returns to `Synced/Healthy` after convergence.

## CRC limitation

OpenShift Local / CRC is a single-node lab. Two replicas on CRC protect against a **pod/process failure**, not against node, hypervisor, storage-zone or site failure.

V6 distinguishes:

1. pod-level HA validated on CRC;
2. stateful/dependency recovery validated on CRC;
3. multi-node / multi-zone HA documented as a production target only.

## Current SPOF catalogue

| Component | V5 | Current V6 CRC | V6 treatment |
|---|---:|---:|---|
| API Gateway | 1 | 2 | N+1 + PDB + pod-kill + full outage/recovery B8 |
| Payment Service | 1 | 2 | N+1 + PDB + pod-kill + concurrent recovery claim B7 |
| Consumer PSP | 1 | 2 | N+1 + PDB + pod-kill |
| Event Audit | 1 | 2 | N+1 + PDB + pod-kill |
| Wero/EPI mock | 1 | 2 | N+1 + PDB + outage tests |
| SCT Inst mock | 1 | 2 | PostgreSQL shared settlement state + PDB + inter-pod failover + full outage B8 |
| PostgreSQL | 1 | 1 | pod recovery on same PVC validated; still a single-instance dependency |
| Redpanda/Kafka | 1 | 1 | Outbox buffering/replay validated; broker still single-instance and ephemeral |
| Keycloak | 1 | 1 | degraded JWT mode + recovery measured; still single-instance |
| CRC node | 1 | 1 | cannot be removed on CRC |

## Important discoveries

### SCT Inst state had to be externalized

Phase A discovered that `mock-sct-inst` kept settlement results in process memory. B4 moved this state to PostgreSQL (`sct_inst_transfers`). Two SCT Inst mock replicas can now share the same settlement and status/reconciliation can move between pods without returning a false `NOT_FOUND`.

### Healthy-path timeout under N+1 load

The first V6 regression exposed a `ProcessingException` because the V5 `consumer-psp` read timeout was 2000 ms. On single-node CRC, N+1 scheduling contention made healthy traffic exceed 2 seconds. CRC therefore uses 4500 ms while the deliberate `TIMEOUT_AFTER_SETTLEMENT` path remains 5 seconds.

This is a lab-specific latency adjustment, not a production SLO recommendation.

### Event-audit JTA boundary and Kafka replay

The audit scheduler clears propagated JTA transaction context before local persistence. If a Kafka record in a batch fails, the consumer does not commit the batch and rewinds involved partitions so records are retried. `eventId` uniqueness keeps replay logically idempotent.

### Keycloak startup and JWK rotation on CRC

Keycloak `start-dev --import-realm` can take long enough that an ordinary liveness probe kills startup. A `startupProbe` protects this window. The ephemeral realm can also generate a new signing key after restart, so the CRC-only overlay reduces Quarkus forced JWK refresh interval to 5 seconds on OIDC resource servers.

These are CRC lab controls, not production Keycloak recommendations.

## Phase A — pod HA

Phase A is validated with `V6 OK (phase A)`.

Observed return to two ready replicas after deleting one pod:

| Workload | Recovery |
|---|---:|
| API Gateway | 10 s |
| Payment Service | 15 s |
| Consumer PSP | 10 s |
| Event Audit | 14 s |
| Wero/EPI mock | 11 s |

A full V4/V5 regression passed before and after pod chaos.

## Phase B1 — PostgreSQL recovery

`tests/resilience/test-v6-postgresql-recovery.sh` passed:

- pre-failure payment `SETTLED`;
- ledger = 1;
- outbox = 3;
- PostgreSQL pod deleted;
- Ready + SQL recovered in **36 s**;
- same `postgresql-data` PVC;
- selected payment/ledger/outbox evidence lost **0 rows**;
- new V4/V5 transaction passed afterward.

This proves recovery of a single PostgreSQL instance on the same persistent volume, not PostgreSQL HA or a production RPO=0 claim.

## Phase B2 — Kafka / transactional Outbox

`tests/resilience/test-v6-kafka-outbox-recovery.sh` passed:

- payment stayed `SETTLED` while Kafka was isolated;
- ledger = 1;
- pending Outbox backlog = **3**;
- failed publish attempts = **2**;
- audit rows during outage = **0**;
- Outbox drained **3/3 in 7 s**;
- audit converged to one logical `PAYMENT_CREATED`, `PAYMENT_PROCESSING`, `PAYMENT_SETTLED`;
- V4/V5 regression passed afterward.

The Redpanda broker is still one ephemeral lab instance. B2 validates Outbox buffering/replay, not broker HA.

## Phase B3 — Keycloak outage

`tests/resilience/test-v6-keycloak-recovery.sh` passed:

- controlled Keycloak scale `1 -> 0` with temporary Argo self-heal suspension;
- already-issued JWT remained usable during outage;
- fresh token acquisition failed during outage;
- token issuance recovered in **131 s**;
- fresh-JWT authorization / JWK convergence recovered in **135 s**;
- Argo returned `Synced/Healthy`;
- V4/V5 regression passed.

This is a time-bounded degraded mode using cached JWT verification, not Keycloak HA.

## Phase B4 — SCT Inst shared state / inter-pod failover

`tests/resilience/test-v6-sct-inst-shared-state.sh` passed with `V6 OK (phase B4)`:

- `TIMEOUT_AFTER_SETTLEMENT` left local payment `UNKNOWN` while shared SCT Inst state was `SETTLED`;
- the pod that accepted the initial SCT Inst POST was identified and deleted;
- a different SCT Inst pod served status/reconciliation;
- the same `settlementId` was returned;
- `UNKNOWN -> SETTLED` reconciliation succeeded;
- exactly one shared rail row and one settlement ledger remained;
- deployment returned to two replicas;
- V4/V5 regression passed afterward.

Detailed design: `docs/architecture/09-sct-inst-shared-state-v6-b4.md`.

## Phase B5 — Wero/EPI outage before the rail

`tests/resilience/test-v6-wero-outage-unknown.sh` passed with `V6 OK (phase B5)`:

- both Wero/EPI mock replicas stopped;
- authorized payment became local `UNKNOWN`;
- SCT Inst shared state contained **0 rows**;
- settlement ledger contained **0 rows**;
- Outbox contained `PAYMENT_CREATED`, `PAYMENT_PROCESSING`, `PAYMENT_UNKNOWN`;
- same idempotency key during outage did not blindly resend;
- Wero recovered to two replicas and Argo `Synced/Healthy` in **11 s**;
- same idempotency key after recovery still did not blindly resend;
- reconciliation returned `railStatus=NOT_FOUND`, `afterStatus=UNKNOWN`;
- V4/V5 regression passed afterward.

This proves the conservative default: an `UNKNOWN` is not automatically converted to failure and is not automatically retried.

## Phase B6 — controlled pre-rail UNKNOWN recovery

`tests/resilience/test-v6-controlled-recovery.sh` passed with `V6 OK (phase B6)`.

Endpoint:

```text
POST /api/payments/{paymentId}/recover
role: payment-reconcile
body: {"confirmation":"RESUBMIT_AFTER_RAIL_NOT_FOUND"}
```

Safety gates:

1. local status must be `UNKNOWN`;
2. explicit confirmation is mandatory;
3. a fresh SCT Inst status preflight runs outside JTA;
4. `SETTLED` or `FAILED` is reconciled without resubmission;
5. unavailable/non-final rail state waits;
6. only `NOT_FOUND` can continue;
7. a conditional database claim `UNKNOWN -> RECOVERY_PENDING` lets only one Payment Service replica own the recovery;
8. the stored payment intent is resubmitted once;
9. final state, ledger and Outbox are committed after the remote result;
10. repeating recovery against a final payment is a no-op.

Observed CRC evidence:

- genuine pre-rail payment reached local `UNKNOWN` with no SCT Inst row and no settlement ledger;
- after Wero/EPI recovery, reconciliation returned `railStatus=NOT_FOUND`, `afterStatus=UNKNOWN`;
- invalid recovery confirmation was rejected before reaching the rail;
- explicit recovery returned `railStatusBefore=NOT_FOUND`, `action=RESUBMITTED`, `afterStatus=SETTLED`;
- exactly **1** SCT Inst rail row remained;
- exactly **1** settlement ledger row remained;
- Outbox contained exactly **1** `PAYMENT_RECOVERY_STARTED` and **1** `PAYMENT_RECOVERED`;
- repeated recovery returned `action=ALREADY_FINAL` and created no duplicate settlement;
- Wero/EPI recovered in **11 s**.

Detailed design and B5/B6 evidence: `docs/architecture/10-wero-outage-controlled-recovery-v6-b5-b6.md`.

## Phase B7 — concurrent controlled recovery

`tests/resilience/test-v6-concurrent-recovery.sh` passed with `V6 OK (phase B7)`.

Eight recovery requests were released simultaneously for the same pre-rail `UNKNOWN` payment through the API Gateway. Observed actions:

- `RESUBMITTED = 1`;
- `RECOVERY_ALREADY_CLAIMED = 1`;
- `RECOVERY_ALREADY_IN_PROGRESS = 6`;
- `ALREADY_FINAL = 0`.

Final invariants:

- payment `SETTLED`;
- SCT Inst rail rows = **1**;
- settlement ledger rows = **1**;
- `PAYMENT_RECOVERY_STARTED = 1`;
- `PAYMENT_RECOVERED = 1`;
- `PAYMENT_SETTLED = 1`;
- `PAYMENT_RECOVERY_FAILED = 0`.

This validates concurrent exclusion of the conditional database claim on CRC. It does not prove node/zone/site HA.

Detailed evidence: `docs/architecture/11-concurrent-controlled-recovery-v6-b7.md`.

## Phase B8 — degraded modes

`tests/resilience/test-v6-degraded-modes.sh` passed twice with `V6 OK (phase B8)`.

The full degraded-mode matrix combines B1 PostgreSQL, B2 Kafka/Outbox, B3 Keycloak, B5 Wero/EPI and the two full-outage experiments added by B8.

### Full SCT Inst outage

Observed on both runs:

- `mock-sct-inst` scaled `2 -> 0`;
- payment became `UNKNOWN`;
- rail rows = 0;
- settlement ledger rows = 0;
- same idempotency key caused no blind replay;
- after SCT Inst recovery, reconciliation returned `NOT_FOUND -> UNKNOWN`;
- explicit controlled recovery produced one `RESUBMITTED -> SETTLED`;
- final rail rows = 1 and settlement ledger rows = 1.

Observed recovery times: **14 s** then **12 s**.

### Full API Gateway outage

Observed on both runs:

- `api-gateway` scaled `2 -> 0`;
- public read/create requests were unavailable (`503` or curl `000` depending timing);
- no payment/rail/ledger side effect was produced by the blocked create;
- after Gateway recovery, the untouched authorized intent was retried;
- payment reached `SETTLED` exactly once.

Observed recovery times: **16 s** then **11 s**.

Detailed matrix: `docs/architecture/12-degraded-modes-v6-b8.md`.

## Final CRC gate

Phase B is fully validated on CRC. V6 CRC is not yet declared complete until one final full regression confirms the post-chaos baseline:

- V4 business + observability regression passes;
- V5 GitOps regression passes;
- V6 Phase A and B1-B8 evidence/scripts remain present and the current runtime is `Synced/Healthy`;
- all expected N+1 deployments are available;
- no durable desired-state drift remains.

## Phase C — production HA target

CRC cannot validate this phase. Target topics remain:

- multiple OpenShift worker nodes and failure domains;
- anti-affinity/topology spread;
- HA ingress/router/load balancing;
- production PostgreSQL HA selected from business RPO/RTO requirements;
- replicated multi-broker Kafka/Redpanda;
- clustered Keycloak with HA backing database;
- resilient secrets/PKI/HSM dependencies where applicable;
- multi-site recovery and tested runbooks.

## RTO / RPO evidence model

For each chaos scenario record:

- failure start/detection;
- minimum surviving service level;
- recovery timestamp and observed RTO;
- data immediately before failure and after recovery;
- observed RPO;
- duplicate/replay count;
- final business state;
- Argo CD and observability state.

No production RPO=0 or RTO target is claimed until a business requirement and matching architecture are explicitly defined.

## GitOps rule

Durable runtime resilience changes stay in Git and are reconciled by Argo CD. Chaos commands are imperative because they represent failures; recovery of declarative resources must come from Kubernetes/OpenShift controllers and GitOps, not from manually rebuilding desired state.
