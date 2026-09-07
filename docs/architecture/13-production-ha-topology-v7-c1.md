# V7 C1 — OpenShift HA topology target

## Purpose

C1 is the first step after the V6 CRC resilience lab. It defines the **target scheduling topology** for the application workloads from local CRC through preproduction and production.

C1 does **not** claim runtime multi-node or multi-zone HA validation. OpenShift Local / CRC is single-node and cannot prove worker, zone or site failure behavior.

Implementation artifacts:

```text
gitops/overlays/crc/kustomization.yaml
gitops/overlays/preprod/kustomization.yaml
gitops/overlays/prod/kustomization.yaml
```

The preproduction and production scaffolds are intentionally annotated:

```text
architecture.mayabanque.io/status: target-not-crc-validated
```

They are not wired to the CRC Argo CD Application.

## Environment progression

| Concern | CRC | Preprod target | Prod target |
|---|---|---|---|
| Namespace | `wero-poc` | `wero-poc-preprod` | `wero-poc-prod` |
| OpenShift topology | single CRC node | >= 2 eligible workers / 2 zone values | >= 3 eligible workers / 3 zone values |
| Application replicas | 2 | 2 | 3 |
| Same-workload placement | same CRC node possible | required anti-affinity by hostname | required anti-affinity by hostname |
| Zone placement | not testable | topology spread, `minDomains: 2` | topology spread, `minDomains: 3` |
| `maxSkew` | n/a | 1 | 1 |
| Unsatisfiable policy | n/a | `DoNotSchedule` | `DoNotSchedule` |
| Application PDB | `minAvailable: 1` | `minAvailable: 1` | `minAvailable: 2` |
| Runtime HA evidence | pod/process/service failures | pending suitable environment | pending suitable environment |

## Workloads covered by C1

The topology policy applies to six application workloads already exercised by V6:

1. `api-gateway`
2. `payment-service`
3. `consumer-psp`
4. `event-audit-service`
5. `mock-wero`
6. `mock-sct-inst`

Stateful platform dependencies such as PostgreSQL, Kafka/Redpanda and Keycloak are **not made HA by C1**. Their production designs are separate C2-C4 work items.

## Worker-level separation

Preprod and prod use required pod anti-affinity:

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
- preprod therefore needs capacity on at least two eligible workers;
- prod with three replicas needs capacity on at least three eligible workers;
- if the rule cannot be satisfied, the missing replica stays unscheduled rather than silently collapsing the intended worker separation.

This is placement policy, not a capacity guarantee. Production sizing must preserve enough CPU, memory and disruption headroom after a worker or zone loss.

## Zone-level spread

### Preprod

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    minDomains: 2
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
```

Target steady state for two replicas and two eligible zones: one replica per zone.

### Production

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    minDomains: 3
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
```

Target steady state for three replicas and three eligible zones: one replica per zone.

Both targets assume eligible workers expose `topology.kubernetes.io/zone` and that sufficient capacity exists while respecting hostname anti-affinity and zone spread.

## PodDisruptionBudget target

Preprod inherits the V6 application PDB baseline:

```yaml
minAvailable: 1
```

Production patches the six application PDBs to:

```yaml
minAvailable: 2
```

A PDB protects voluntary disruptions. It does not itself prevent an involuntary worker or zone outage and does not replace failure-domain placement, spare capacity or dependency HA.

## Expected failure behavior

### One application pod fails

Production target expectation:

- two replicas remain available;
- the Deployment controller creates a replacement;
- the replacement must still respect hostname anti-affinity and zone spread.

V6 validated pod-level recovery on CRC, but distributed C1 placement remains unvalidated until executed on a real multi-worker environment.

### One worker fails

Architectural expectation:

- required hostname anti-affinity limits a given C1 workload to at most one replica on the lost worker;
- surviving replicas remain on other workers;
- a replacement is possible only if sufficient eligible capacity remains.

This must be tested on a real multi-worker cluster before being called validated.

### One zone fails

With the intended production 3-zone placement:

- one application replica per workload can be lost with the failed zone;
- two application replicas remain in the other zones;
- end-to-end continuity still depends on surviving ingress, DNS, storage, database, messaging, IAM and network dependencies.

Therefore C1 alone does **not** establish an end-to-end zone-HA claim.

## CI evidence

The repository CI uses pinned Kustomize to render all three desired-state variants:

```text
CRC -> preprod -> prod
```

For preprod it asserts:

- six application Deployments with `replicas: 2`;
- six PDBs with `minAvailable: 1`;
- six required pod anti-affinity rules;
- six hostname topology keys;
- six zone topology-spread keys;
- six `minDomains: 2` constraints;
- namespace `wero-poc-preprod`.

For production it asserts:

- six application Deployments with `replicas: 3`;
- six PDBs with `minAvailable: 2`;
- six required pod anti-affinity rules;
- six hostname topology keys;
- six zone topology-spread keys;
- six `minDomains: 3` constraints;
- namespace `wero-poc-prod`.

For CRC, preprod and prod, CI also rejects a rendered runtime `Secret` committed into desired state.

This is **configuration/render validation**, not runtime HA validation.

## C1 completion boundary

C1 is now **defined and render-validated** for CRC, preprod and prod.

Still open for C1:

- runtime validation on an OpenShift environment with the required workers and failure domains;
- worker-loss and zone-loss exercises;
- evidence that sufficient spare capacity exists during those failures.

C1 must not be described as runtime multi-node/multi-zone validated before those tests exist.

## What remains before a production deployment is credible

### C2 — PostgreSQL HA

Replace the single PostgreSQL Deployment + single-PVC production model with an HA database architecture chosen against business RPO/RTO, including failover, backup/restore and PITR.

### C3 — Kafka/Redpanda HA

Define multi-broker replication, quorum, storage and broker-failure behavior.

### C4 — Keycloak HA

Define clustered Keycloak instances backed by an HA database with production session and key behavior.

### C5 — ingress / load balancer / DNS HA

Ensure the public entry path does not remain a separate single failure domain.

### C6 — business RTO/RPO

Define RTO/RPO by payment capability and map them to infrastructure validation criteria.

### C7 — multi-site / PRA and runbooks

Define site-loss behavior, replication/failover strategy, operational decision points and tested recovery procedures.

## GitOps and delivery work still required

Before real preprod/prod deployment, the repository still needs:

- immutable image promotion by digest instead of `:latest`;
- Argo CD Applications bound to actual preprod/prod clusters/namespaces;
- environment-specific Routes/DNS/TLS and external dependencies;
- environment-specific secrets supplied outside Git;
- progressive-delivery policy where required.
