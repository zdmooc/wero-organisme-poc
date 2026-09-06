# V6 — SPOF / Chaos / HA / Resilience

## Goal

V6 turns the V5 GitOps deployment into a resilience lab. The objective is not to claim production-grade HA on CRC, but to identify every single point of failure, inject controlled failures, measure recovery and progressively remove avoidable SPOFs.

The V5 business invariants remain mandatory after every V6 experiment:

- consent and SCA remain valid;
- payment can reach `SETTLED` when required dependencies are available;
- idempotency prevents duplicate business execution;
- ledger remains coherent;
- transactional outbox preserves events;
- Kafka audit retains `paymentId`, `correlationId` and trace continuity;
- Prometheus, Jaeger and Grafana remain usable;
- Argo CD remains `Synced/Healthy` after convergence.

## CRC limitation

OpenShift Local / CRC is a single-node lab. Two replicas on CRC protect against a **pod/process failure**, not against node, hypervisor, storage-zone or site failure.

V6 therefore distinguishes:

1. **pod-level HA validated on CRC**;
2. **stateful recovery validated on CRC**;
3. **multi-node / multi-zone HA documented as production target only** until a suitable cluster exists.

## Initial SPOF catalogue

| Component | V5 baseline | V6 phase A | Failure consequence | V6 treatment |
|---|---:|---:|---|---|
| API Gateway | 1 replica | 2 replicas | public payment API unavailable | N+1 + PDB + pod-kill test |
| Payment Service | 1 | 2 | payment orchestration unavailable | N+1 + PDB + pod-kill test |
| Consumer PSP | 1 | 2 | synchronous payment chain unavailable | N+1 + PDB + pod-kill test |
| Event Audit | 1 | 2 | audit consumption delayed | N+1 + PDB + pod-kill test |
| Wero/EPI mock | 1 | 2 | simulated external orchestration unavailable | N+1 + PDB + pod-kill test |
| SCT Inst mock | 1 | 1 | simulated rail/status unavailable | explicit SPOF until settlement state is externalized |
| PostgreSQL | 1 | 1 | state/ledger/outbox unavailable | explicit phase-B SPOF |
| Redpanda/Kafka | 1 | 1 | event publication/consumption unavailable | explicit phase-B SPOF; outbox must buffer |
| Keycloak | 1 | 1 | new token acquisition / IAM path impacted | explicit phase-B SPOF |
| CRC node | 1 node | 1 node | complete lab outage | cannot be removed on CRC |
| OpenShift router/DNS/control plane | CRC-managed | CRC-managed | routing/control-plane outage | observe/document; multi-node target later |

## Important discovery: mock-sct-inst is stateful

`mock-sct-inst` stores settlement results in an in-process map. Two replicas would therefore not share settlement state: a payment could settle on one pod while a later status/reconciliation request reaches another pod and returns `NOT_FOUND`.

For phase A, CRC deliberately keeps `mock-sct-inst` at one replica. It must not be presented as stateless HA until its settlement state is moved to a shared durable store or the mock is redesigned to be deterministically stateless.

## Important discovery: healthy-path timeout under N+1 load

The first V6 regression exposed a `ProcessingException` on the Payment Service because the V5 `consumer-psp` read timeout was 2000 ms. On single-node CRC, adding N+1 replicas increased local scheduling contention enough for the normal synchronous chain to exceed 2 seconds.

For V6 CRC the healthy-path timeout is therefore 4500 ms. This remains below the intentional `TIMEOUT_AFTER_SETTLEMENT` failure scenario, where the rail mock sleeps for 5 seconds after settlement, so the designed `UNKNOWN`/reconciliation behavior remains testable.

This is a lab-specific latency budget adjustment, not a production SLO recommendation.

## Important discovery: event-audit JTA boundary and Kafka replay

Phase-B preparation exposed the same Narayana context-leak pattern previously fixed in the Payment Service: `event-audit-service` could fail with `Enlisted connection used without active transaction` while persisting a Kafka record from a scheduler thread.

Two protections are now explicit:

- scheduler thread context clears propagated JTA `Transaction` state before `AuditStore` starts its own synchronous local transaction;
- if any record in a polled Kafka batch fails, the consumer does not commit the batch and rewinds each involved partition to the earliest offset in that batch so the records are retried.

`eventId` is unique in the audit database, so replay remains logically idempotent even when earlier records in the failed batch are processed again.

## Phase A — stateless N+1 and pod chaos

Five workloads are treated as truly stateless in phase A:

- `api-gateway`
- `payment-service`
- `consumer-psp`
- `event-audit-service`
- `mock-wero`

Each runs with two replicas and a `PodDisruptionBudget` with `minAvailable: 1`.

The chaos test deliberately deletes one pod directly, then verifies that at least one ready replica survives and that the Deployment returns to two ready replicas.

V6 phase A test sequence:

```text
V5 regression on V6 desired state
        |
        v
verify 2 ready replicas + PDB for five stateless workloads
        |
        v
for each stateless workload:
  delete one running pod
  verify >= 1 ready survivor
  wait for 2 ready replicas
  measure recovery seconds
        |
        v
record PostgreSQL/Kafka/Keycloak/mock-sct-inst as known SPOFs
        |
        v
full V5 business + observability regression again
```

The test is `tests/resilience/test-v6-pod-ha.sh`.

### Phase A runtime evidence

Phase A is validated on CRC. The complete test finished with `V6 OK (phase A)` after a successful V5/V4 business and observability regression both before and after pod chaos.

Observed recovery to two ready replicas after deleting one pod:

| Workload | Observed recovery |
|---|---:|
| API Gateway | 10 s |
| Payment Service | 15 s |
| Consumer PSP | 10 s |
| Event Audit | 14 s |
| Wero/EPI mock | 11 s |

At least one replica remained ready in every case. PostgreSQL, Kafka, Keycloak and `mock-sct-inst` remained explicit single-replica SPOFs and were not falsely presented as HA.

## Phase B — stateful and dependency chaos

Phase B starts only after phase A passes on CRC. That entry criterion is now satisfied.

### PostgreSQL pod failure — phase B1

Test: `tests/resilience/test-v6-postgresql-recovery.sh`.

The scenario:

- creates a known `SETTLED` payment through the full V5 regression;
- captures payment, ledger and outbox evidence plus the PVC identity;
- deletes the only PostgreSQL pod;
- waits for a different PostgreSQL pod to become Ready and answer SQL;
- measures observed recovery time;
- verifies the same `postgresql-data` PVC is still attached;
- verifies the committed payment status and selected ledger/outbox row counts survived unchanged;
- waits for Argo CD to be `Synced/Healthy`;
- runs a new full V5 business/observability transaction after recovery.

#### Phase B1 runtime evidence

Phase B1 is validated on CRC:

- selected pre-failure payment: `SETTLED`;
- selected ledger evidence: 1 row;
- selected outbox evidence: 3 rows;
- PostgreSQL pod recovery to Ready + SQL: **36 s**;
- `postgresql-data` PVC identity remained unchanged;
- selected payment/ledger/outbox evidence lost **0 rows**;
- a new full V4/V5 business and observability regression succeeded after recovery.

This proves recovery of this single-instance PostgreSQL deployment from a pod/process restart while reusing the same persistent volume. It does **not** prove PostgreSQL HA and does **not** establish a production RPO of zero.

### Kafka / Redpanda outage — phase B2

Implemented test: `tests/resilience/test-v6-kafka-outbox-recovery.sh`.

The first B2 scenario injects a deterministic Kafka connectivity outage with a temporary `NetworkPolicy` instead of racing a short pod restart. The broker remains single-replica; only payment/audit connectivity to the Kafka pod is intentionally denied during the failure window.

The scenario:

- starts from a full healthy V5/V4 regression;
- isolates the Kafka pod from in-namespace clients;
- creates and authorizes a new payment while Kafka is unreachable;
- verifies the business transaction and ledger still commit to PostgreSQL;
- verifies at least one unpublished outbox row accumulates and records a failed publish attempt;
- restores Kafka connectivity;
- measures time until all three payment outbox events are published;
- waits until audit contains exactly one logical `PAYMENT_CREATED`, `PAYMENT_PROCESSING` and `PAYMENT_SETTLED` event;
- runs a new full V5/V4 regression after recovery.

This scenario validates transactional-outbox buffering and replay semantics. It does not make the broker HA. The current Redpanda lab still uses one replica and ephemeral broker data under `/tmp`, so broker-level durability/RPO remains a separate limitation to address.

### Keycloak outage

- validate behavior with an already-issued JWT;
- validate failure of fresh token acquisition while IAM is unavailable;
- restore Keycloak and measure recovery;
- ensure no secrets are exposed by the test.

### SCT Inst state and failover

Before claiming N+1 for `mock-sct-inst`, externalize or redesign its settlement state, then verify that a status query can land on a different pod without losing the final settlement state.

### External Wero / SCT Inst timeout

- inject unavailability/timeout;
- verify the payment enters the designed `UNKNOWN`/reconciliation path instead of blind replay;
- restore the rail;
- reconcile to the final state;
- verify idempotency and ledger invariants.

## Phase C — production HA target

CRC cannot validate this phase. The target architecture should eventually include:

- multiple OpenShift worker nodes and failure domains;
- hard pod anti-affinity / topology spread across nodes or zones;
- HA ingress/router and external load balancing;
- production-grade PostgreSQL HA with synchronous/asynchronous replication chosen from RPO/RTO requirements;
- multi-broker Kafka/Redpanda with replicated partitions;
- clustered Keycloak backed by an HA database;
- resilient secrets/PKI/HSM dependencies where applicable;
- multi-site recovery design and tested runbooks.

## RTO / RPO evidence model

For each chaos scenario record:

- failure start timestamp;
- detection timestamp;
- minimum surviving service level;
- recovery timestamp;
- observed RTO;
- data created immediately before the failure;
- data present after recovery;
- observed RPO;
- duplicate/replay count;
- final business status;
- Argo CD and observability state after recovery.

No RPO=0 or RTO target is claimed until a business requirement and a matching architecture are explicitly defined.

## GitOps rule

All durable runtime resilience changes stay in Git and are reconciled by Argo CD. Chaos commands are imperative by design because they represent failures; recovery of declarative resources must come from Kubernetes/OpenShift controllers and GitOps, not from manually rebuilding desired state.

## Entry criteria

V5 is runtime validated by the CRC run that ended with both `V4 OK` and `V5 OK` on V5 head `7207f94`.

## Exit criteria for V6 phase A

All phase-A criteria are now satisfied on CRC:

1. Argo CD was `Synced/Healthy` on `v6-spof-chaos-ha-resilience`;
2. all five stateless deployments had two ready replicas;
3. all five PDBs had `minAvailable=1`;
4. `mock-sct-inst` remained explicitly single-replica until state is externalized;
5. one pod was deleted from each stateless workload without losing every ready replica;
6. every stateless deployment recovered to two ready replicas;
7. the post-chaos V5 business/observability regression ended with `V4 OK` and `V5 OK`;
8. the test ended with `V6 OK (phase A)`.
