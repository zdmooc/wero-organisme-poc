# V7 C1 — Production OpenShift HA topology target

## Purpose

C1 is the first step after the V6 CRC resilience lab. It defines the **target scheduling topology** for application workloads on a real multi-node / multi-zone OpenShift platform.

C1 does **not** claim that production HA has been validated. OpenShift Local / CRC is single-node and cannot prove worker, zone or site failure behavior.

The implementation artifact is:

```text
gitops/overlays/prod/kustomization.yaml
```

The overlay is intentionally marked:

```text
architecture.mayabanque.io/status: target-not-crc-validated
```

It is not wired to the CRC Argo CD Application.

## From V6 CRC to the production target

| Concern | V6 CRC | V7 C1 production target |
|---|---|---|
| OpenShift workers | single CRC node | at least 3 schedulable workers |
| Failure domains | one node | at least 3 zone values |
| Application replicas | 2 | 3 |
| Same-workload pod placement | same node possible on CRC | required anti-affinity by hostname |
| Zone placement | not testable | topology spread across zones |
| Application PDB | `minAvailable: 1` | `minAvailable: 2` |
| Runtime validation | pod/process/service failures | multi-node/multi-zone validation still pending |

## Workloads covered by C1

C1 applies the production scheduling policy to the six application workloads already exercised by V6:

1. `api-gateway`
2. `payment-service`
3. `consumer-psp`
4. `event-audit-service`
5. `mock-wero`
6. `mock-sct-inst`

Each target Deployment renders with:

```yaml
replicas: 3
```

Stateful platform dependencies such as PostgreSQL, Kafka/Redpanda and Keycloak are **not made HA by C1**. Their production designs are separate C2-C4 work items.

## Worker-level separation

Each workload has required pod anti-affinity:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: <workload>
        topologyKey: kubernetes.io/hostname
```

Intent:

- two replicas of the same workload must not be scheduled on the same worker;
- with three replicas, the target therefore requires capacity on at least three eligible workers;
- if the cluster cannot satisfy this rule, the unschedulable replica must remain Pending rather than silently collapsing the intended failure-domain separation.

This is a placement policy, not a capacity guarantee. Production capacity planning must reserve enough CPU, memory and disruption headroom on the remaining workers.

## Zone-level spread

Each workload also has:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    minDomains: 3
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: <workload>
```

Target assumptions:

- eligible workers expose `topology.kubernetes.io/zone`;
- at least three distinct zone values are available;
- the cluster has sufficient capacity to place the replicas while respecting both hostname anti-affinity and zone spread.

With three replicas and three eligible zones, the intended steady state is one replica per zone.

## PodDisruptionBudget target

For each of the six workloads C1 changes:

```yaml
minAvailable: 2
```

This protects against voluntary disruptions that would reduce the workload below two available replicas.

A PDB is not a protection against every failure type. It does not itself prevent an involuntary worker or zone outage and it does not replace topology placement, spare capacity or dependency HA.

## Expected failure behavior

### One application pod fails

Expected target behavior:

- two replicas remain available;
- the Deployment controller creates a replacement;
- scheduling must continue to respect hostname anti-affinity and zone spread.

V6 already validated pod-level recovery on CRC, but C1's distributed placement is not CRC-validatable.

### One worker fails

Architectural expectation:

- at most one replica of a given C1 workload was on that worker because of required hostname anti-affinity;
- surviving replicas remain on other workers;
- a replacement can be scheduled only if sufficient eligible capacity exists elsewhere.

This must be tested on a real multi-worker environment before being called validated.

### One zone fails

Architectural expectation with the intended 3-zone placement:

- one replica per workload may be lost with the failed zone;
- two replicas remain in the other zones;
- service continuity still depends on surviving capacity, ingress, DNS, storage, database, messaging, IAM and network dependencies.

Therefore C1 alone does **not** establish an end-to-end zone-HA claim.

## CI evidence

The repository CI renders both CRC and production overlays with pinned Kustomize.

For the production overlay it asserts:

- six application Deployments with `replicas: 3`;
- six PDBs with `minAvailable: 2`;
- six required pod anti-affinity rules;
- six hostname topology keys;
- six zone topology-spread keys;
- six `minDomains: 3` constraints;
- production namespace `wero-poc-prod`;
- no runtime `Secret` manifest committed into rendered desired state.

This is **configuration/render validation**, not runtime HA validation.

## What remains before a production deployment is credible

C1 deliberately leaves these concerns open:

### C2 — PostgreSQL HA

Replace the single PostgreSQL Deployment + RWO PVC design with a production HA database architecture, then define backup/restore and failure behavior against business RPO/RTO.

### C3 — Kafka/Redpanda HA

Define multi-broker replication, quorum, storage and broker-failure behavior.

### C4 — Keycloak HA

Define clustered Keycloak instances backed by an HA database and production key/session behavior.

### C5 — ingress / load balancer / DNS HA

Ensure public entry does not remain a separate single failure domain.

### C6 — business RTO/RPO

Define required RTO/RPO by payment capability before claiming that the infrastructure design satisfies them.

### C7 — multi-site / PRA and runbooks

Define site-loss behavior, replication/failover strategy, operational decision points and tested recovery procedures.

## GitOps and delivery work still required

The production overlay is an architecture scaffold. Before deployment it also needs:

- immutable image promotion by digest instead of `:latest`;
- a coherent `preprod` overlay and promotion path;
- production-specific Routes/DNS/TLS and external dependencies;
- environment-specific secrets supplied outside Git;
- progressive-delivery policy where required.

## C1 validation boundary

C1 can be considered **defined and render-validated** when its Kustomize/CI checks pass.

C1 must **not** be described as runtime multi-node or multi-zone validated until the same desired state is exercised on an OpenShift environment with the required workers and failure domains.
