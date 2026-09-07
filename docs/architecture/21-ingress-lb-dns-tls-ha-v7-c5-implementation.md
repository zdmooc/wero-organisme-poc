# V7 C5 — Ingress / LB / DNS / TLS HA — implementation evidence

## Status

**C5 design/Git/render validated. Runtime frontdoor HA remains open.**

This document records what is now implemented in Git and what still requires a real OpenShift environment with real DNS, certificates and load-balancer integration.

## Implemented artifacts

### Architecture

- `docs/architecture/20-ingress-lb-dns-tls-ha-v7-c5.md`

### Cluster-scoped ingress target

- `gitops/cluster/ingress-ha/preprod-ingresscontroller.yaml`
- `gitops/cluster/ingress-ha/prod-ingresscontroller.yaml`
- `gitops/cluster/ingress-ha/kustomization.yaml`

Target replicas:

```text
preprod = 2 routers
prod    = 3 routers
```

Dedicated route shards:

```text
preprod-public
prod-public
```

The generic scaffold deliberately does not commit:

- a public ingress `domain`;
- `defaultCertificate`;
- `endpointPublishingStrategy`;
- environment-specific `nodePlacement`.

Those values require the real platform design and are not safe to guess in a provider-neutral repository.

## Public Route component

Implemented in:

- `gitops/components/frontdoor-ha/routes.yaml`
- `gitops/components/frontdoor-ha/kustomization.yaml`

Only two public Routes are part of C5:

```text
api-gateway-public
keycloak-public
```

### API Gateway

Target:

```text
HTTPS client -> OpenShift router -> HTTP api-gateway Service
```

Route policy:

```text
TLS termination = edge
HTTP             = redirect to HTTPS
```

No public hostname is invented in the generic component.

### Keycloak

Target:

```text
HTTPS client
  -> OpenShift router
      -> HTTPS re-encrypt
          -> keycloak Service :8443
              -> Keycloak pods
```

Route policy:

```text
TLS termination = reencrypt
HTTP             = redirect to HTTPS
backend port     = https
```

## Keycloak service-serving certificate

C5 adds the OpenShift service-ca contract in the environment overlays:

```yaml
service.beta.openshift.io/serving-cert-secret-name: keycloak-service-tls
```

and configures the Keycloak Operator target to consume:

```text
tlsSecret        = keycloak-service-tls
httpsPort        = 8443
serviceHttpsPort = 8443
```

The Secret is generated/provisioned at runtime by the cluster service-ca mechanism. No Secret manifest or private key is stored in Git.

The existing C4 internal compatibility contract remains enabled:

```text
http://keycloak:8080
```

Therefore C5 requires **no Java source modification and no application-specific rebuild**.

A later hardening migration may move internal OIDC discovery from HTTP to HTTPS, but that is not silently claimed as completed here.

## C5 layered overlays

To avoid rewriting the large C1-C4 environment overlays, C5 is implemented as an explicit additional layer.

### Preproduction

- `gitops/overlays/preprod-c5/kustomization.yaml`

Composes:

```text
preprod C1-C4 target
+ public frontdoor component
```

C5 removes the CRC/base convenience Routes from the public target:

- `api-gateway`
- `jaeger`
- `prometheus`
- `grafana`

The previous `keycloak` lab Route was already removed by C4.

The two C5 Routes are assigned to shard:

```text
preprod-public
```

### Production

- `gitops/overlays/prod-c5/kustomization.yaml`

Same public exposure policy, assigned to:

```text
prod-public
```

## Observability exposure boundary

Jaeger, Prometheus and Grafana are deliberately **not** public C5 Routes.

C5 does not invent an administrative access solution. Real environments must use an approved internal/administrative access path such as corporate ingress, VPN, bastion or another controlled pattern.

## CI gates

Dedicated workflow:

- `.github/workflows/ci-v7-frontdoor.yml`

It renders and verifies:

- both IngressController targets;
- preprod router count = 2;
- prod router count = 3;
- route shard selectors;
- no hard-coded provider-specific ingress domain/LB strategy/default certificate;
- exactly two public Routes in each C5 environment target;
- API Gateway edge TLS + redirect;
- Keycloak re-encrypt + redirect + HTTPS backend;
- Keycloak service-ca annotation and TLS Secret reference;
- retained internal `keycloak:8080` contract;
- no `kind: Secret` in rendered C5 desired state;
- shell syntax of the C5 runtime runbook.

Final consolidation evidence before C5 closure:

```text
C5 workflow #12  SUCCESS
C4 workflow #54  SUCCESS
global CI #390   SUCCESS
```

## Runtime runbook scaffold

Added:

- `tests/production/test-v7-ingress-failover.sh`

The script implements a guarded C5-F1 router-pod-loss exercise.

Required real inputs include:

```text
INGRESS_CONTROLLER
API_GATEWAY_PUBLIC_HOST
KEYCLOAK_PUBLIC_HOST
```

Safety behavior:

- dry-run by default;
- requires at least two router pods;
- refuses to delete a pod unless `ALLOW_DESTRUCTIVE_C5=true`;
- deletes only one router pod;
- checks both API Gateway HTTPS readiness and Keycloak OIDC discovery;
- records observed recovery time;
- explicitly states that one router-pod test is not proof of worker/zone/LB/DNS/site HA.

## Environment prerequisites still open

Before applying C5 on a real target, platform architecture must define and provision:

- real immutable ingress domain;
- API Gateway public hostname;
- Keycloak public hostname;
- external/load-balancer publication strategy;
- real router node placement and failure-domain labels;
- approved public certificate lifecycle;
- DNS records and TTL;
- LB health checks/backends;
- final Keycloak public hostname/proxy configuration;
- final NetworkPolicy allowing only the trusted ingress path where applicable;
- administrative access pattern for observability.

## Runtime evidence still open

C5-F1 through C5-F6 remain runtime evidence gates:

- router pod loss;
- router worker loss;
- router zone loss;
- external LB target loss;
- certificate rotation;
- DNS/failover behavior when DNS participates in recovery.

For Keycloak, runtime validation must include:

- HTTPS OIDC discovery;
- token endpoint;
- JWK endpoint;
- stable issuer/public hostname;
- router-to-Keycloak TLS validation;
- no exposure of the management port as public application traffic.

## Evidence boundary

Current repository state proves the **desired-state architecture and render/security invariants** only.

It does not prove:

- real external LB HA;
- router placement across real workers/zones;
- public DNS availability;
- certificate trust/rotation;
- measured production RTO/RPO;
- site-level disaster recovery.

C6 will define business RTO/RPO acceptance targets; C7 will address multi-site/PRA.
