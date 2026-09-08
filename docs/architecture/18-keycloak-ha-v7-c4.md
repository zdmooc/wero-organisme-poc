# V7 C4 — Keycloak HA reference architecture

## Status

**Architecture decision / implementation target. Runtime HA validation is still open.**

C4 replaces the V6/CRC Keycloak lab model for the preproduction/production target. CRC remains intentionally unchanged until an environment capable of running the Keycloak Operator, CloudNativePG and multiple failure domains is available.

## Current V6 lab model

The working CRC baseline uses:

```text
Deployment keycloak
replicas = 1
strategy = Recreate
command = start-dev --import-realm
HTTP 8080
hostname-strict = false
realm JSON mounted from ConfigMap
```

This is suitable for the local POC but not for production HA.

Important limitations:

- one Keycloak pod;
- `start-dev` uses local caches and disables distributed cache clustering;
- no production-grade external Keycloak database;
- no independent failure-domain placement;
- realm bootstrap is tied to server startup;
- no production hostname / TLS contract;
- bootstrap admin is a lab mechanism, not a production administration model.

V6 B3 proved a degraded-mode behavior for one Keycloak pod and cached JWT/JWK use. It did **not** prove Keycloak HA.

## C4 decision

For this repository, the reference target is:

```text
Keycloak Operator
  + Keycloak CR v2beta1
  + production-mode Keycloak
  + embedded distributed Infinispan
  + jdbc-ping discovery through the Keycloak database
  + dedicated CloudNativePG HA database
```

The Keycloak server and Operator image versions must be kept aligned during lifecycle upgrades.

## Why a dedicated Keycloak database

C4 deliberately does **not** reuse the MayaBanque payment database cluster as the Keycloak datastore.

Target separation:

```text
Payment domain                IAM domain
--------------                ----------
mayabank-postgresql           mayabank-keycloak-postgresql
wero DB                       keycloak DB
payment/ledger/outbox         realms/users/sessions/config
```

Reasons:

- avoid correlated saturation between payment writes and authentication traffic;
- isolate maintenance and schema lifecycle;
- isolate database connection pools;
- permit IAM-specific backup/restore and sizing;
- make IAM RTO/RPO evidence independently measurable;
- reduce the blast radius of application-database incidents.

Both database clusters may still use the same approved CloudNativePG platform/operator, but they are separate PostgreSQL clusters with separate storage and credentials.

## Target logical architecture

```text
                         +-----------------------+
Clients / API Gateway -->| OpenShift ingress/LB |
                         +-----------+-----------+
                                     |
                              Keycloak Service
                                     |
                 +-------------------+-------------------+
                 |                   |                   |
                 v                   v                   v
          +-------------+     +-------------+     +-------------+
          | Keycloak A  |     | Keycloak B  |     | Keycloak C  |
          | production  |     | production  |     | production  |
          +------+------+     +------+------+     +------+------+
                 |                   |                   |
                 +-----------+-------+-------------------+
                             |
                 embedded Infinispan cluster
                   discovery = jdbc-ping
                             |
                             v
                  +-------------------------+
                  | Keycloak PostgreSQL RW |
                  +------------+------------+
                               |
             +-----------------+-----------------+
             |                 |                 |
             v                 v                 v
       PostgreSQL A      PostgreSQL B      PostgreSQL C
       primary/standby   primary/standby   primary/standby
       independent PVC   independent PVC   independent PVC
```

## Keycloak instance count

### Preproduction

Target:

```text
instances: 2
```

The preprod application topology already models two failure zones. Two Keycloak server instances are enough for basic pod/node failover exercises while keeping the environment smaller than production.

The dedicated PostgreSQL cluster still uses three database instances so database promotion behavior can be exercised independently.

### Production

Target:

```text
instances: 3
```

Intended placement:

- one Keycloak pod per eligible worker;
- spread across three zone values when the environment exposes three zones;
- strict worker separation;
- strict zone spread when sufficient capacity exists.

The Keycloak Operator has availability-oriented scheduling defaults, but this repository makes the required production failure-domain intent explicit rather than relying only on `ScheduleAnyway` defaults.

## Production mode and distributed cache

The target must use production mode, not `start-dev`.

Production mode enables distributed caching for multi-node Keycloak. The default supported cache transport for the 26.x line is `jdbc-ping`, where Keycloak nodes register/discover cluster membership through the configured database.

Target cache model:

```text
cache = ispn
cache stack = jdbc-ping (default production stack)
```

C4 does not use the deprecated Kubernetes DNS cache stack.

The embedded cache is not a substitute for the database. Realm/user/session durability requirements continue to depend on the Keycloak database and the Keycloak persistence model.

## Dedicated PostgreSQL HA target

Reference cluster name:

```text
mayabank-keycloak-postgresql
```

Reference database:

```text
keycloak
```

Reference owner/runtime Secret:

```text
keycloak-db
```

The Secret is created outside Git and uses the `kubernetes.io/basic-auth` contract expected by the CNPG bootstrap pattern.

Target database topology:

```text
instances: 3
one independent PVC per instance
anti-affinity across workers/failure domains
```

Because the Keycloak HA blueprint depends on a database that tolerates zone failure, C4 targets synchronous replication to one standby for this IAM database. This is a configuration target, not a claim that the environment has achieved `RPO=0`.

The final measured RTO/RPO remains a C6 validation concern.

## Stable DB endpoint

Keycloak connects only to the role-aware CNPG read/write service:

```text
mayabank-keycloak-postgresql-rw:5432
```

The Keycloak Operator receives database username/password by Secret reference. No password belongs in Git.

## Keycloak Operator target

Reference CR API:

```text
apiVersion: k8s.keycloak.org/v2beta1
kind: Keycloak
```

C4 uses the Operator rather than hand-maintaining a production `Deployment` because the Operator owns the Keycloak server lifecycle, health handling and rolling-update semantics.

The environment must install an Operator version aligned with the Keycloak operand version. Operator upgrades should be controlled and tested in preprod before production.

## Hostname / TLS boundary

C4 deliberately does not invent a production DNS name or certificate.

The final public hostname, TLS termination mode, OpenShift Route / ingress and load-balancer behavior belong to C5.

Before a Keycloak CR is connected to a real environment, C5 must provide:

- explicit frontend hostname;
- TLS certificate contract;
- proxy/header or passthrough mode;
- health-check integration;
- external/load-balancer path.

The production target must not rely on the current CRC setting:

```text
KC_HOSTNAME_STRICT=false
```

as a substitute for a designed public URL.

## Health and observability

Target production deployment enables:

```text
health = enabled
metrics = enabled
```

Readiness traffic must be based on Keycloak readiness rather than only a TCP socket. The upstream load-balancer/ingress must stop sending traffic to an instance that is not ready.

C4 should expose Keycloak metrics to the existing observability architecture in a later runtime iteration.

## Realm bootstrap migration

The V6 lab uses `--import-realm` on every server start with a realm JSON ConfigMap.

The production target must separate server lifecycle from realm provisioning.

Preferred migration path for this POC:

1. export/transform the current MayaBanque realm definition;
2. create a `KeycloakRealmImport` CR using `k8s.keycloak.org/v2beta1`;
3. reference Secrets through realm-import placeholders when a sensitive value is required;
4. run the one-time import;
5. verify condition `Done`;
6. remove the import CR/job after successful bootstrap;
7. manage subsequent realm configuration changes through an explicit administrative/configuration lifecycle rather than startup re-import.

A `KeycloakRealmImport` creates a realm only when it does not already exist; it is not a continuous reconciliation mechanism for existing realm changes.

## Admin bootstrap boundary

The current `KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD` path is a lab bootstrap.

Production administration must use a controlled bootstrap procedure followed by:

- named administrative identities;
- least privilege;
- MFA;
- audited administration;
- removal/rotation of one-time bootstrap credentials.

The repository will not store production admin credentials.

## Session and signing-key considerations

Keycloak server instances share persistent realm configuration and keys through the database-backed Keycloak model and clustered cache behavior. C4 validation must verify that a pod failure does not invalidate healthy client authentication unexpectedly.

Tests must cover at least:

- existing access token verification while one Keycloak pod is lost;
- new token issuance after pod loss;
- OIDC discovery/JWK availability;
- login/session continuity;
- refresh-token behavior;
- signing-key/JWK consistency across surviving instances.

Do not infer those outcomes merely from multiple replicas being `Ready`.

## Failure scenarios

### C4-F1 — Keycloak pod loss

- obtain an authenticated session/token baseline;
- delete one Keycloak pod;
- verify remaining instance(s) continue serving readiness/OIDC/token traffic;
- verify no incorrect issuer/JWK change;
- measure interruption/RTO.

### C4-F2 — Keycloak worker loss

On a real multi-worker environment:

- lose the worker hosting one Keycloak pod;
- confirm traffic is routed to surviving pods;
- confirm replacement placement on an eligible worker;
- record session/token effects.

### C4-F3 — Keycloak zone loss

On a multi-zone environment:

- remove one Keycloak failure domain;
- validate surviving server capacity;
- validate database availability;
- record login/token RTO and errors.

### C4-F4 — Keycloak DB primary loss

- identify current `mayabank-keycloak-postgresql` primary;
- fail the primary;
- validate CNPG promotion;
- verify Keycloak JDBC reconnection;
- verify new token issuance and existing realm/user state;
- record DB and IAM RTO.

### C4-F5 — rolling update

- roll one Keycloak version-compatible change;
- ensure readiness removes/re-adds pods correctly;
- verify login/token continuity during update;
- record any interruption.

### C4-F6 — realm/bootstrap recovery

- prove a fresh non-production IAM environment can bootstrap the MayaBanque realm through the Operator import workflow without embedding secrets in Git.

## RTO/RPO evidence

Capture for each failure test:

```text
failure timestamp
Keycloak pods before/after
worker/zone placement
database primary before/after
OIDC discovery status
token endpoint status
JWK availability
first successful login/token after failure
observed RTO
observed data-loss/session-loss symptoms
```

C4 does not translate one successful test into an SLA. C6 owns business-level RTO/RPO objectives and acceptance thresholds.

## Implementation sequence

1. **C4-A — architecture decision** — this document.
2. **C4-B — dedicated CNPG Keycloak database scaffold**.
3. **C4-C — Keycloak Operator CR scaffold**, not wired to CRC.
4. **C4-D — preprod/prod scheduling and environment patches**.
5. **C4-E — realm-import migration scaffold** without secrets in Git.
6. **C4-F — failure-test scripts/runbooks** for a multi-worker environment.
7. **C4-G — measured evidence mapped to C6 RTO/RPO**.

## Evidence boundary

C4 architecture can be render-validated in CI, but a local CRC cluster cannot prove:

- distributed Keycloak server HA across workers/zones;
- database synchronous failover characteristics;
- login/session continuity under worker/zone loss;
- ingress/load-balancer HA;
- production RTO/RPO;
- site-level disaster recovery.

Those claims remain open until runtime evidence exists on an appropriate environment.
