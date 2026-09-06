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

Therefore V6 distinguishes:

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
| SCT Inst mock | 1 | 2 | simulated rail unavailable | N+1 + PDB + pod-kill test |
| PostgreSQL | 1 | 1 | state/ledger/outbox unavailable | explicit phase-B SPOF |
| Redpanda/Kafka | 1 | 1 | event publication/consumption unavailable | explicit phase-B SPOF; outbox must buffer |
| Keycloak | 1 | 1 | new token acquisition / IAM path impacted | explicit phase-B SPOF |
| CRC node | 1 node | 1 node | complete lab outage | cannot be removed on CRC |
| OpenShift router/DNS/control plane | CRC-managed | CRC-managed | routing/control-plane outage | observe/document; multi-node target later |

## Phase A — stateless N+1 and pod chaos

The six Java runtime components in the synchronous/audit chain use `replicas: 2` on the V6 branch.

Each has a `PodDisruptionBudget` with `minAvailable: 1`. This protects voluntary disruption paths. The chaos test deliberately deletes a pod directly, which is stronger than a voluntary eviction and verifies that the Deployment controller recreates it while another ready replica remains.

V6 phase A test sequence:

```text
V5 regression on V6 desired state
        |
        v
verify 2 ready replicas + PDB
        |
        v
for each stateless component:
  delete one running pod
  verify >= 1 ready survivor
  wait for 2 ready replicas
  measure recovery seconds
        |
        v
record PostgreSQL/Kafka/Keycloak as known SPOFs
        |
        v
full V5 business + observability regression again
```

The test is `tests/resilience/test-v6-pod-ha.sh`.

## Phase B — stateful and dependency chaos

Phase B will be implemented only after phase A passes on CRC.

Planned experiments:

### PostgreSQL pod failure

- create a known payment and ledger state;
- delete the PostgreSQL pod;
- measure database recovery time using the existing PVC;
- verify the previously committed payment, ledger and outbox records still exist;
- verify a new payment succeeds after recovery;
- record observed RTO;
- do **not** claim database HA: a single PostgreSQL instance is still a SPOF.

### Kafka / Redpanda outage

- stop/delete the Kafka pod during payment activity;
- verify business database commits are not lost;
- verify unpublished rows remain in `outbox_events`;
- restore Kafka;
- verify outbox drains and audit receives each event once logically through deduplication;
- measure backlog drain and recovery time.

### Keycloak outage

- validate behavior with an already-issued JWT;
- validate failure of fresh token acquisition while IAM is unavailable;
- restore Keycloak and measure recovery;
- ensure no secrets are exposed by the test.

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

V6 keeps **target** and **observed** values separate.

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

V5 must already be runtime validated. This is satisfied by the CRC run that ended with both `V4 OK` and `V5 OK` on V5 head `7207f94`.

## Exit criteria for V6 phase A

Phase A is complete only when CRC output proves:

1. Argo CD is `Synced/Healthy` on `v6-spof-chaos-ha-resilience`;
2. all six stateless deployments have two ready replicas;
3. all six PDBs have `minAvailable=1`;
4. one pod can be deleted from each component without losing every ready replica;
5. every deployment recovers to two ready replicas;
6. the post-chaos V5 business/observability regression ends with `V4 OK` and `V5 OK`;
7. the test ends with `V6 OK (phase A)`.
