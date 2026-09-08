# V7 C4 — Keycloak HA implementation evidence

## Status

**C4 design and Git/Kustomize implementation are complete and render-validated. Runtime HA validation remains open.**

This document records what is actually implemented on branch `v7-production-ha-architecture`. It does not claim multi-worker, multi-zone, RTO/RPO or disaster-recovery evidence.

## Implemented resources

C4 adds the autonomous component:

```text
gitops/components/keycloak-ha/
├── kustomization.yaml
├── keycloak.yaml
├── keycloak-db.yaml
└── pdb.yaml
```

The component contains:

- `Keycloak/mayabank-keycloak` using `k8s.keycloak.org/v2beta1`;
- `Cluster/mayabank-keycloak-postgresql` using CloudNativePG;
- `PodDisruptionBudget/mayabank-keycloak`;
- no runtime `Secret` manifest.

## Keycloak target

### Preproduction

```text
Keycloak instances = 2
PDB minAvailable = 1
worker anti-affinity = required
worker topology minDomains = 2
zone topology minDomains = 2
```

### Production

```text
Keycloak instances = 3
PDB minAvailable = 2
worker anti-affinity = required
worker topology minDomains = 3
zone topology minDomains = 3
```

The scheduling intent is explicit in Git. CRC cannot validate that the pods actually land on different workers or zones.

## Dedicated IAM database

Keycloak uses a database cluster independent from the payment database:

```text
Cluster: mayabank-keycloak-postgresql
Database: keycloak
Instances: 3
RW endpoint: mayabank-keycloak-postgresql-rw:5432
Credential Secret: keycloak-db
```

The Secret is provisioned outside Git.

The target synchronous policy requires acknowledgement from one standby:

```yaml
postgresql:
  synchronous:
    method: any
    number: 1
    dataDurability: required
```

This is a desired-state durability target, not proof of `RPO=0`.

## Stable internal OIDC contract

The existing Quarkus services use:

```text
http://keycloak:8080/realms/mayabanque
```

C4 deliberately preserves that internal contract through the Keycloak Operator CR:

```yaml
http:
  httpEnabled: true
  httpPort: 8080
  serviceHttpPort: 8080
  serviceName: keycloak
```

Therefore **C4 requires no Java rebuild**.

The public hostname, TLS termination, OpenShift Route/Ingress, load balancer and external health-check contract remain C5 responsibilities.

## Migration away from the CRC Keycloak lab

The preprod and prod overlays remove the V6 lab resources:

```text
Deployment/keycloak
Service/keycloak
Route/keycloak
```

They add `../../components/keycloak-ha` instead.

CRC remains unchanged and continues to use its single-pod `start-dev` model for local functional tests. CRC is not presented as proof of Keycloak HA.

## Cache/session model

The target runs Keycloak in production mode under the Operator. The architecture relies on the supported embedded distributed Infinispan model with database-backed `jdbc-ping` discovery.

Multiple replicas alone do not prove session continuity or signing-key/JWK behavior. Those properties remain runtime test requirements.

## Realm bootstrap

C4 adds a one-shot bootstrap scaffold:

```text
gitops/bootstrap/keycloak/mayabanque-realm-import.yaml
```

It is intentionally excluded from the continuously reconciled preprod/prod Kustomize resources because `KeycloakRealmImport` is a create/import workflow, not continuous reconciliation of an existing realm.

The scaffold:

- targets `mayabank-keycloak`;
- preserves the MayaBanque realm roles, client and demonstration users;
- stores no password in Git;
- uses `sslRequired: external` for the target realm;
- must be applied only after Keycloak is Ready;
- must be checked for `Done=true` and then removed.

Administrative/bootstrap credentials are provisioned and rotated outside Git.

## CI evidence

Two layers validate the desired state:

### Dedicated C4 gate

`.github/workflows/ci-v7-keycloak.yml` checks:

- Keycloak CR API/name/instance baseline;
- dedicated CNPG database and synchronous target;
- stable internal Service contract `keycloak:8080`;
- worker/zone scheduling intent;
- explicit Keycloak PDB and Operator pod labels;
- no runtime Secret manifest.

At head `69a6ba987b19ed6cb1a8cad0ed45aaca424384fb`, the dedicated C4 workflow **#22 succeeded**.

### Global V7 gate

`.github/workflows/ci-v2.yml` renders CRC, preprod and prod and retains the C1-C3 invariants while validating the C4 additions.

At the same head, the global workflow **#358 succeeded**.

## Evidence still required

C4 is not production-validated until an appropriate OpenShift environment proves at least:

- C4-F1: Keycloak pod loss;
- C4-F2: worker loss;
- C4-F3: zone loss;
- C4-F4: dedicated Keycloak DB primary loss and JDBC recovery;
- C4-F5: rolling Keycloak update;
- C4-F6: fresh-environment one-shot realm bootstrap;
- existing-token verification during failure;
- new token issuance after failure;
- OIDC discovery and JWK availability;
- login/session/refresh-token continuity;
- signing-key/JWK consistency;
- measured IAM RTO and observed persistence/session-loss behavior.

C6 owns the final business RTO/RPO objectives and acceptance thresholds. C7 owns site-level disaster recovery.
