# V7 C2 — PostgreSQL backup, WAL archive and PITR target

## Status

**Architecture/runbook target — not runtime validated.**

This document extends C2 beyond high availability. Three PostgreSQL replicas protect service continuity against some instance failures, but replicas are not independent backups and do not provide Point-In-Time Recovery by themselves.

## Current technology direction

For new CloudNativePG deployments, this repository uses the **Barman Cloud CNPG-I Plugin** as the reference direction for object-store backups and WAL archiving.

Reason: current CloudNativePG documentation deprecates the older in-tree `spec.backup.barmanObjectStore` integration in favor of the plugin architecture. The plugin supports online physical backup, continuous WAL archiving, restore and PITR.

Official references:

- https://cloudnative-pg.io/docs/1.29/wal_archiving/
- https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/
- https://cloudnative-pg.io/plugin-barman-cloud/docs/concepts/

The repository deliberately does not invent an S3/Azure/GCS bucket, credentials, retention period or encryption key. Those are environment/security decisions.

## Target architecture

```text
CNPG primary + standbys
        |
        | WAL archive + physical base backup
        v
Barman Cloud CNPG-I Plugin
        |
        v
ObjectStore CR
        |
        v
External object storage
  S3 / Azure Blob / GCS / approved compatible store
```

The object store must be outside the same single storage failure domain as the database PVCs.

## Required platform prerequisites

Before enabling this target:

1. CloudNativePG operator version compatible with the selected plugin;
2. Barman Cloud Plugin installed and supported by the platform team;
3. certificate/TLS prerequisites for CNPG-I communication;
4. an approved object-storage target;
5. credentials delivered outside Git;
6. network policy allowing the required object-store path;
7. retention, encryption and deletion policy approved by security/operations;
8. monitoring and alerting for WAL archive and backup failures.

## Cluster plugin integration

Once an environment-specific `ObjectStore` exists, the CNPG `Cluster` target is extended conceptually with:

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: mayabank-postgresql
```

`barmanObjectName` must match the environment's `ObjectStore` resource.

This stanza is **not yet wired into the shared C2 component** because the object-storage provider, endpoint and credential mechanism have not been selected. Wiring it without a real `ObjectStore` would create an incomplete desired state.

## Scheduled base backups

CloudNativePG recommends `ScheduledBackup` resources for recurring backups. With the plugin method, an environment-specific policy follows this shape:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: mayabank-postgresql
spec:
  cluster:
    name: mayabank-postgresql
  backupOwnerReference: self
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  schedule: "<six-field-cron-approved-by-operations>"
```

The schedule is intentionally not chosen here. CloudNativePG uses a six-field cron including seconds, which differs from the usual five-field Unix crontab.

## WAL archiving and RPO

Continuous WAL archiving is required for PITR.

The technical archive interval is not the same thing as the business RPO. C6 must decide the acceptable transaction-loss window and the design must then prove that:

- synchronous/asynchronous streaming replication policy satisfies failover RPO expectations;
- WAL shipping/object-store availability satisfies disaster-recovery/PITR expectations;
- monitoring detects archive lag or failure before the recovery window is silently lost.

No `RPO=0` claim is made by this document.

## Secret handling

Do not commit:

- object-store access keys;
- Azure storage keys/SAS tokens;
- GCS service-account keys;
- PostgreSQL passwords;
- TLS private keys.

Git may contain only secret references or external-secret integration definitions approved for the target environment.

## C2-F5 — restore exercise

A backup is not considered valid until it has been restored.

Required evidence for a restore lab:

1. select a known completed base backup;
2. create a **separate recovery cluster**;
3. restore from object storage;
4. verify selected payment IDs, ledger rows and Outbox/audit markers;
5. prove the source production/preproduction cluster was not modified by the exercise;
6. record restore start/end timestamps and observed restore RTO;
7. destroy the recovery environment only after evidence is captured.

The restore cluster must use separate Kubernetes resources and storage from the source cluster.

## C2-F6 — PITR exercise

Use deterministic markers around a target timestamp:

```text
T0  create marker/payment A
T1  target recovery timestamp
T2  create marker/payment B
T3  perform PITR into a separate recovery cluster
```

Expected proof after recovery to `T1`:

- marker/payment A exists;
- marker/payment B does not exist;
- ledger/outbox state is internally coherent at the selected recovery point;
- recovery target and timeline are recorded.

Do not run PITR destructively against the active cluster for this exercise.

## Failure modes to monitor

At minimum alert on:

- WAL archiving failures;
- stale/no successful base backup;
- object-store authentication failure;
- retention/deletion failure;
- recovery test failure;
- backup duration or size anomaly;
- insufficient object-store capacity/quota;
- loss of redundancy in the CNPG cluster.

## C2 completion boundary

The repository can claim **backup/PITR architecture defined** when this design is approved and provider-specific resources are supplied.

It can claim **backup/PITR validated** only after C2-F5 and C2-F6 have been executed successfully on an appropriate environment with evidence retained.

CRC is not used as proof of multi-worker PostgreSQL HA or production-grade disaster recovery.
