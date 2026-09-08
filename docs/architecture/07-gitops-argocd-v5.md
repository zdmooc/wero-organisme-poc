# V5 — GitOps / OpenShift GitOps / Argo CD

## Goal

V5 replaces the imperative runtime deployment model used by `deploy-v1.sh` through `deploy-v4.sh` with a declarative desired state stored in Git and continuously reconciled by Argo CD.

The lab keeps the build plane separate: Maven + OpenShift binary BuildConfigs produce the six Java images. Argo CD does not build application code; it owns runtime Kubernetes/OpenShift resources.

## Control loop

```text
GitHub branch v5-gitops-argocd
        |
        v
Kustomize gitops/overlays/crc
        |
        v
OpenShift GitOps / Argo CD
        |
        +--> compare desired vs live
        +--> sync
        +--> prune previously managed resources removed from Git
        +--> self-heal runtime drift
        v
OpenShift namespace wero-poc
```

## Repository structure

```text
gitops/
  base/
    kustomization.yaml
    infrastructure.yaml
    runtime.yaml
    observability.yaml
    networking-routes.yaml
    mayabanque-realm.json
  overlays/
    crc/
      kustomization.yaml
  argocd/
    project.yaml
    application.yaml
```

`base` is the reusable desired state. `overlays/crc` adds the local CRC namespace and GitOps metadata. Future environments must be added as dedicated overlays rather than copied scripts.

## Argo CD application

Application: `wero-poc-crc`

Source:
- repository: `zdmooc/wero-organisme-poc`
- branch: `v5-gitops-argocd`
- path: `gitops/overlays/crc`

Destination:
- cluster: local OpenShift cluster
- namespace: `wero-poc`

Automated policy:
- `prune: true`
- `selfHeal: true`
- retry with exponential backoff

The `AppProject` restricts the application to this repository and the `wero-poc` destination namespace.

## What Git owns

Git owns:
- PostgreSQL PVC, Deployment and Service;
- Redpanda/Kafka Deployment and Service;
- Keycloak Deployment, Service and realm configuration;
- API Gateway;
- payment-service;
- consumer-psp;
- event-audit-service;
- mock-wero;
- mock-sct-inst;
- Jaeger;
- Prometheus;
- Grafana and dashboard provisioning;
- public OpenShift Routes;
- NetworkPolicies preserving V3B backend isolation.

Direct Routes for `payment-service` and `event-audit-service` are intentionally absent.

## Secrets

Runtime secrets are deliberately not committed to Git.

The bootstrap creates or reuses:
- `postgresql`;
- `keycloak-admin`;
- `wero-v3-app`;
- `wero-v3-demo-users`.

This CRC lab uses OpenShift Secrets. A production evolution should replace bootstrap-generated secrets with an external secrets solution backed by an enterprise vault/HSM according to the security architecture.

## Image lifecycle

For CRC, Deployments reference the OpenShift internal registry ImageStream tags produced by the build plane.

This is intentionally a lab compromise. Production GitOps should use immutable image digests or immutable version tags and promote an image by pull request changing the desired image reference in Git. Runtime image mutation outside Git must not become the production model.

## Drift

V5 explicitly tests drift reconciliation:

1. Git declares `api-gateway.spec.replicas = 1`.
2. The E2E test changes the live Deployment to `replicas = 2`.
3. Argo CD detects the difference.
4. `selfHeal` restores `replicas = 1`.
5. Application returns to `Synced`.

This demonstrates the core GitOps rule: Git is the desired-state authority; manual cluster changes are not durable configuration.

## Rollback

The operational rollback model is Git-native:

1. identify the last known-good commit;
2. revert the faulty Git commit or restore the previous manifest/image reference;
3. merge/push the rollback change;
4. Argo CD reconciles the cluster back to that desired state;
5. validate application health, traces, metrics and business E2E tests.

A production deployment should combine this with immutable artifact versions, protected branches, required reviews and CI policy checks.

## Installation choice

V5 uses the Red Hat OpenShift GitOps Operator from OperatorHub. The operator provides the OpenShift-integrated Argo CD control plane in `openshift-gitops`, which is more appropriate for this OpenShift lab than applying generic upstream Kubernetes manifests manually.

The bootstrap discovers the installed catalog source and default operator channel dynamically instead of hard-coding a catalog channel.

## Validation target

`tests/e2e/test-v5-gitops.sh` validates:
- OpenShift GitOps operator and Argo CD server;
- Application `Synced` + `Healthy`;
- Git/Kustomize metadata on managed resources;
- secrets absent from the GitOps desired-state tree;
- V3B Route isolation and NetworkPolicies;
- all Git-managed workloads ready;
- deliberate replica drift automatically healed;
- complete V4 payment + Kafka + OpenTelemetry + Prometheus + Jaeger + Grafana regression.

Expected final line:

```text
V5 OK: Git/Kustomize -> OpenShift GitOps/Argo CD -> automated sync/prune/self-heal, secrets outside Git, V4 payment and observability regression successful.
```

## Out of scope / next step

V5 does not claim production HA. PostgreSQL, Kafka/Redpanda, Keycloak and observability components still contain deliberate CRC single-instance SPOFs.

V6 will attack those assumptions directly: SPOF inventory, failure injection, degraded modes, chaos tests, recovery, RTO/RPO and HA/resilience patterns.
