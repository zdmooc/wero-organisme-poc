# V7 C3 — Redpanda / Kafka HA reference architecture

## Status

**Architecture decision / implementation target — not runtime validated.**

C3 replaces the V6/CRC single-broker Redpanda development model for preproduction and production. CRC remains unchanged.

## Current V6 messaging model

The base currently runs:

```text
Deployment kafka
replicas = 1
Redpanda --mode=dev-container
/tmp/redpanda-data
no persistent volume
Service kafka:9092
```

This is appropriate for the CRC lab but has several production SPOFs:

- one broker;
- broker process and node are the same failure domain;
- ephemeral broker data;
- topic replication can remain at the Redpanda default of 1;
- no rack/zone awareness;
- no controlled broker lifecycle/decommission model;
- no production TLS/SASL design;
- no disaster-recovery copy.

V6 B2 proved that the transactional Outbox protects business publication while the single broker is unavailable and drains after recovery. That is application resilience evidence, not Kafka/Redpanda HA.

## C3 decision

For this repository, the reference target remains **Redpanda**, managed by the **Redpanda Operator**.

The application contract remains Kafka-compatible. `payment-service` continues to produce Kafka records and `event-audit-service` continues to consume them. C3 changes the broker platform, not the business event model.

A real bank may instead standardize on Apache Kafka/Strimzi, Confluent Platform or a managed Kafka service. That enterprise product choice is separate from the HA principles captured here.

## Why the Redpanda Operator

Current Redpanda guidance recommends the Operator for production Kubernetes lifecycle management. The current Redpanda resource API is:

```yaml
apiVersion: cluster.redpanda.com/v1alpha2
kind: Redpanda
```

The target benefits are:

- declarative GitOps desired state;
- StatefulSet-managed broker identity;
- controlled rolling lifecycle;
- broker decommission support;
- persistent volume per broker;
- rack awareness based on Kubernetes failure-domain labels;
- production-oriented Redpanda configuration instead of `--mode=dev-container`.

## Broker topology

### Preproduction

Reference topology:

```text
3 brokers
3 independent persistent volumes
2+ workers
2+ zones when available
```

Preproduction mirrors the three-broker quorum topology, even when it cannot provide full three-zone isolation.

### Production

Reference topology:

```text
Broker 0 -> worker A -> zone A -> PVC A
Broker 1 -> worker B -> zone B -> PVC B
Broker 2 -> worker C -> zone C -> PVC C
```

Production requires at least three brokers. An odd broker count is retained for consensus behavior.

The target must not schedule all brokers onto the same worker. Rack awareness uses:

```text
topology.kubernetes.io/zone
```

so partition replicas can be distributed across failure zones.

Three brokers alone do not prove zone HA. The topic replication factor, storage topology, worker capacity, Kubernetes control plane, networking and client configuration must also be correct.

## Persistent storage

Each broker owns its own data volume.

Production requirements:

- XFS or ext4 for the Redpanda data directory;
- PVC per broker;
- StorageClass compatible with the intended worker/zone topology;
- capacity and IOPS sized from workload evidence;
- no NFS for the Redpanda data directory;
- no use of `/tmp` as broker persistence.

The repository must treat any initial PVC size as a scaffold placeholder, not a production sizing claim.

## Topic replication policy

The business topic is:

```text
payment-events
```

C3 target:

```text
replication factor = 3
```

Redpanda recommends RF=3 for most use cases. With three brokers, each partition therefore has one leader and two additional replicas.

The cluster target should also prevent accidental creation of under-replicated topics by setting the minimum topic replication policy to 3 where supported by the selected Redpanda version.

Changing the cluster default does not retroactively repair an existing RF=1 topic. Migration/validation must explicitly verify the actual replica assignment of `payment-events`.

## Producer acknowledgement and business correctness

Replication factor and producer acknowledgement are separate controls.

For payment-domain events, C3 must validate the producer durability policy used by the Kafka client. The architecture target is to evaluate `acks=all` against latency and availability objectives rather than assuming the broker topology alone prevents acknowledged-event loss.

The existing transactional Outbox remains mandatory:

```text
business DB commit
      |
      v
transactional Outbox
      |
      +--> retry until Kafka accepts the event
```

Redpanda HA reduces broker outage impact; it does not replace the Outbox.

## Application bootstrap endpoint

The current lab uses:

```text
kafka:9092
```

The Redpanda production Kubernetes target uses the Operator/Helm internal listener, whose default Kafka port is `9093`.

Clients must receive a broker bootstrap list/endpoint through environment-specific configuration, not Java source changes. Quarkus already reads `kafka.bootstrap.servers`, so preprod/prod can override the runtime value.

The exact internal DNS names must come from the deployed Redpanda resource. A typical same-namespace three-broker topology is equivalent to:

```text
redpanda-0.redpanda:9093
redpanda-1.redpanda:9093
redpanda-2.redpanda:9093
```

Do not hard-code external NodePort/LoadBalancer addresses for in-cluster producers/consumers.

## Rack awareness

Rack awareness is required in the production target.

The selected rack source is the Kubernetes node failure-domain label:

```text
topology.kubernetes.io/zone
```

Intent:

- broker placement spans workers;
- Redpanda knows which zone/rack hosts each broker;
- replicas of a partition are distributed across distinct racks where possible;
- losing one of three zones leaves a majority of RF=3 replicas available, assuming the remaining infrastructure is healthy.

This must be validated at runtime; YAML alone is insufficient.

## Security target

The current CRC broker is intentionally simple. Production C3 must define:

- TLS for Kafka API traffic;
- TLS for administrative/inter-broker interfaces according to the platform standard;
- SASL or approved identity mechanism;
- least-privilege ACLs for producer and consumer identities;
- credentials and private keys outside Git;
- certificate lifecycle and rotation;
- NetworkPolicy allowing only required clients and management paths.

Security configuration is part of production readiness, but C3 does not invent credentials or certificate issuers before the target environment is known.

## Failure scenarios

### C3-F1 — one broker pod failure

Validate:

- cluster remains healthy enough to produce/consume `payment-events`;
- partition leadership moves where required;
- RF remains 3 after broker recovery;
- Outbox backlog does not grow indefinitely;
- no duplicate logical audit event;
- observed interruption/RTO is recorded.

### C3-F2 — broker worker failure

On a real multi-worker environment:

- lose the worker hosting one broker;
- verify surviving quorum and client continuity;
- verify broker replacement/recovery behavior;
- capture under-replicated/leaderless partition metrics.

### C3-F3 — one zone failure

On a three-zone environment:

- remove one rack/zone;
- verify RF=3 topics remain available with the two surviving replicas;
- verify no leaderless `payment-events` partition remains;
- measure business publication/consumption interruption.

### C3-F4 — broker decommission / maintenance

Validate planned maintenance using the Operator-supported decommission lifecycle rather than deleting broker storage blindly.

### C3-F5 — full broker outage / recovery

Preserve the V6 B2 business invariant:

- payment transactions can commit to PostgreSQL/Outbox while Kafka is unavailable according to application policy;
- events drain after Kafka recovery;
- Event Audit receives each logical event once according to the application deduplication model.

## Observability evidence

For every C3 runtime exercise record:

```text
failure timestamp
broker membership before/after
rack/zone placement
topic replication factor
leaderless partition count
under-replicated partition count
producer acknowledgement errors
Outbox pending count
consumer lag / audit arrival
first successful event after recovery
observed RTO
```

Do not convert one successful test into a production SLA.

## Disaster recovery boundary

A healthy three-broker, three-zone cluster addresses zonal HA, not site/region disaster recovery.

C7 must decide whether the target requires:

- independent secondary cluster + Shadowing;
- Stretch Cluster where business requirements justify synchronous cross-location behavior;
- Tiered Storage / Whole Cluster Restore where a higher RPO/RTO is acceptable;
- another enterprise-standard Kafka DR mechanism.

The decision must follow C6 RPO/RTO objectives.

## C3 implementation sequence

1. **C3-A** — architecture decision and prerequisites — this document.
2. **C3-B** — Redpanda Operator 3-broker scaffold for preprod/prod.
3. **C3-C** — remove the single-broker lab Deployment/Service from preprod/prod.
4. **C3-D** — configure client bootstrap endpoints without Java changes.
5. **C3-E** — ensure `payment-events` RF=3 and minimum topic replication policy.
6. **C3-F** — add broker-failure/decommission lab scripts.
7. **C3-G** — runtime broker/worker/zone failure evidence.
8. **C3-H** — map results to C6 RTO/RPO and C7 DR.

## C3 validation boundary

C3 may be described as **architecture-defined** once this target is accepted.

It may be described as **render-validated** after the Operator manifests are built by CI.

It may be described as **runtime HA validated** only after broker, worker and zone failure exercises succeed on an appropriate multi-worker environment.

CRC remains the V6 functional/resilience lab and is not evidence of multi-broker or multi-zone Redpanda HA.
