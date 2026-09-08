# V7 C2 — PostgreSQL HA reference architecture

## Status

**Architecture decision / implementation scaffold.**

C2 replaces the V6/CRC single-instance PostgreSQL model for the preproduction/production target. It does not change the working CRC database yet and does not claim a production RPO/RTO before business objectives are defined in C6.

## Current V6 database model

The current GitOps base deliberately uses a lab-oriented PostgreSQL deployment:

```text
Deployment postgresql
replicas = 1
strategy = Recreate
PVC postgresql-data
accessMode = ReadWriteOnce
Service postgresql
```

V6 B1 proved that this instance can recover on the same PVC after a pod restart. That evidence is valuable for persistence/recovery, but it is not PostgreSQL HA.

Current SPOFs:

- one PostgreSQL process/pod;
- one writable PVC;
- no hot standby;
- no automated database-primary failover;
- no independent replica storage;
- no production backup/PITR architecture in Git;
- application Service points to the only database pod.

## C2 decision

For this repository, the **reference implementation is CloudNativePG (CNPG)**.

This is a repository architecture choice, not a statement that every bank should standardize on CNPG. A real production program must also validate enterprise support, platform certification, security, lifecycle, operational ownership and procurement requirements.

### Why CNPG fits this POC

The reference target needs:

- declarative GitOps configuration;
- PostgreSQL native physical streaming replication;
- primary plus standby instances;
- automated failover/switchover;
- stable read/write service independent of which pod is primary;
- separate persistent storage per PostgreSQL instance;
- backup/WAL archiving and Point-In-Time Recovery capability;
- Kubernetes/OpenShift-aware lifecycle management.

CNPG provides these primitives without forcing the application services to implement database failover logic.

### Alternative retained for enterprise evaluation

**Crunchy Postgres for Kubernetes / PGO** remains a valid alternative to evaluate for a supported enterprise platform. It provides HA, automated primary recovery, synchronous replication options and pgBackRest-based backup/restore capabilities.

The selection must ultimately be governed by the target organization's supported-product catalog and RPO/RTO requirements.

## Target logical architecture

```text
                       +-----------------------+
Payment Service ------>| PostgreSQL RW Service |
SCT Inst Mock -------->|       stable DNS      |
                       +-----------+-----------+
                                   |
                        current primary endpoint
                                   |
             +---------------------+---------------------+
             |                     |                     |
             v                     v                     v
      +-------------+       +-------------+       +-------------+
      | PostgreSQL  |       | PostgreSQL  |       | PostgreSQL  |
      | instance A  |       | instance B  |       | instance C  |
      | primary or  |       | primary or  |       | primary or  |
      | standby     |       | standby     |       | standby     |
      +------+------+       +------+------+       +------+------+
             |                     |                     |
             v                     v                     v
        PVC A / zone A        PVC B / zone B        PVC C / zone C

                 physical streaming replication

                         +------------------+
                         | object storage   |
                         | base backups/WAL |
                         +------------------+
```

The primary role is not attached permanently to a specific pod. Applications use the operator-managed RW service; when failover promotes a standby, the service follows the new primary.

## Instance count

### Preproduction target

Minimum reference topology:

```text
instances: 3
```

Reason: meaningful failover testing needs one primary and at least two independent candidate standbys if the environment is intended to model production behavior.

The surrounding application layer can remain at its C1 preprod replica target while the database topology deliberately mirrors production quorum/failover behavior.

### Production target

Reference topology:

```text
instances: 3
```

Intended placement:

- one PostgreSQL instance per eligible worker;
- one PostgreSQL instance per failure domain/zone when the storage platform supports that topology;
- independent PVC per instance;
- no shared single RWO PVC between primary and replicas.

Three instances do not by themselves guarantee zone HA. Worker topology, storage topology, Kubernetes control-plane availability and the operator itself must all be designed consistently.

## Replication policy and RPO

C2 deliberately does **not** hard-code a claim of `RPO=0`.

Two operating modes must be considered against C6 business objectives.

### Asynchronous replication

Advantages:

- lowest write latency;
- primary can continue writing if replicas are temporarily unavailable.

Trade-off:

- a sudden primary loss can leave a small amount of acknowledged WAL not yet present on the promoted standby;
- therefore a non-zero data-loss window is possible.

### Synchronous replication

Advantages:

- an acknowledged commit can be required to reach a synchronous standby before PostgreSQL returns success;
- appropriate when transaction-loss tolerance is extremely low.

Trade-offs:

- extra commit latency;
- write availability can be affected if the required synchronous standby set cannot be satisfied.

**C6 must choose the policy from business RPO/RTO, not from infrastructure preference.**

For payment settlement data, the conservative architecture recommendation is to evaluate synchronous replication first, measure latency under target load, and make the availability/latency trade-off explicit.

## Stable application endpoint

The application must stop depending on a Service that selects a fixed `app: postgresql` pod set without database-role awareness.

Target connection pattern:

```text
payment-service ----+
                    +--> <cluster>-rw:5432
mock-sct-inst ------+
```

Read/write traffic goes only to the current primary through the operator-managed RW service.

If future read-only workloads are introduced, they may use a replica/read-only service separately. Payment writes, ledger writes and Outbox transactions remain on the RW endpoint.

## Transaction invariants

C2 must preserve the invariants already proven by V2-V6:

- payment state and settlement ledger commit atomically where required;
- transactional Outbox remains in the same PostgreSQL transaction boundary;
- no payment is considered safely persisted before database commit;
- recovery/failover must not create duplicate settlement ledger rows;
- controlled `UNKNOWN` recovery semantics remain unchanged;
- database failover must be transparent to idempotency keys and payment IDs.

HA must not weaken correctness.

## Storage requirements

Each database instance requires independent persistent storage.

Production storage must provide:

- a supported CSI StorageClass;
- durable volumes independent of pod lifetime;
- topology compatible with the selected zones;
- enough IOPS/latency for PostgreSQL WAL and data workloads;
- volume expansion procedure;
- snapshot/backup integration where used;
- documented behavior when a node or zone becomes unavailable.

C1 scheduling topology and C2 storage topology must agree. A pod that can move zones is not useful if its required storage cannot recover or be recreated safely in the target failure scenario.

## Backup, WAL archive and PITR

HA replicas are **not backups**.

The production design needs a separate recovery path:

```text
PostgreSQL cluster
  |
  +--> scheduled/base backup
  +--> continuous WAL archive
             |
             v
       external object storage
```

Required capabilities:

- periodic physical/base backups;
- continuous WAL archiving;
- retention policy;
- encryption in transit and at rest;
- backup credentials outside Git;
- restore into a new cluster;
- Point-In-Time Recovery test;
- restoration evidence independent of the running HA replicas.

The object store must not share the same single failure domain as the primary database storage.

## Failure scenarios to validate

C2 is not complete merely because three database pods are Running.

### C2-F1 — primary pod failure

Inject:

```text
delete current primary pod
```

Validate:

- exactly one new primary is elected;
- RW service points to the new primary;
- application reconnects;
- committed payment/ledger/outbox evidence remains coherent;
- no duplicate settlement;
- observed failover RTO recorded.

### C2-F2 — primary worker failure

On a real multi-worker environment:

- lose or isolate the worker hosting the primary;
- confirm promotion on another worker/failure domain;
- record service interruption and data position before/after failover.

This cannot be proven on CRC.

### C2-F3 — standby failure

Validate:

- writes continue according to the configured replication policy;
- replacement standby is recreated safely;
- cluster returns to intended redundancy.

### C2-F4 — planned switchover

Validate controlled maintenance:

- promote a standby deliberately;
- confirm client reconnection;
- no application data inconsistency;
- return cluster to healthy topology.

### C2-F5 — backup restore

Restore a known backup into a separate cluster and validate selected payment/ledger/outbox records.

### C2-F6 — PITR

Create deterministic data markers around a recovery timestamp, restore to the selected point and prove expected-before / absent-after records.

## RTO/RPO evidence model

For every database failure test capture:

```text
failure timestamp
old primary
new primary
RW service convergence
last committed payment/ledger/outbox markers before failure
first successful transaction after recovery
replication position / recovery evidence
observed RTO
observed data-loss window
```

Do not translate a single successful test into a production SLA. C6 defines the target; repeated tests demonstrate whether the architecture meets it.

## Migration from the current lab Deployment

The V6 CRC PostgreSQL Deployment remains unchanged while C2 is being designed.

A production migration must be explicit. Candidate approaches include:

1. logical export/import for this small POC data set;
2. physical backup/recovery when source/target compatibility permits;
3. logical replication for a lower-downtime migration if a future environment needs it.

For this repository, the initial non-production C2 implementation may bootstrap a fresh HA cluster and run the full E2E suite against it. That must not be confused with a production data-migration runbook.

## Secret handling

No database password, backup credential or object-store key belongs in Git.

Git contains only references to secret names or external secret mechanisms. Runtime credentials remain environment-managed, consistent with the V3/V5 security model.

## C2 implementation sequence

1. **C2-A — operator decision and prerequisites** — this document.
2. **C2-B — declarative CNPG cluster scaffold** for preprod/prod, not wired to CRC.
3. **C2-C — application endpoint migration** from lab `postgresql` Service to environment-specific RW service.
4. **C2-D — backup/WAL/PITR configuration** with credentials outside Git.
5. **C2-E — failover/switchover test scripts** for a real multi-worker environment.
6. **C2-F — backup restore and PITR exercises**.
7. **C2-G — map measured evidence to C6 RPO/RTO targets**.

## C2 decision boundary

C2 currently selects CloudNativePG as the **reference architecture for this repository**.

Before any real production use, confirm:

- supported OpenShift/Kubernetes versions;
- operator lifecycle and upgrade policy;
- enterprise support model;
- PostgreSQL version lifecycle;
- storage and object-store compatibility;
- security hardening requirements;
- monitoring/alerting integration;
- target RPO/RTO and synchronous-replication policy.

Until those checks and runtime tests exist, C2 is an architecture target, not a production HA certification.
