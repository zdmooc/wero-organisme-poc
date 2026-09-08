# V7 C5 — Ingress / Load Balancer / DNS / TLS HA

## Status

**Architecture target / render-validation scope. Runtime HA proof remains open.**

C5 defines the MayaBanque north-south frontdoor for the V7 production target. It does not claim that CRC proves router, external load-balancer, DNS, certificate or failure-domain HA.

The target is intentionally provider-neutral: no cloud provider, public IP, public DNS zone, load-balancer implementation or production certificate is invented in Git.

## Scope

C5 owns:

- OpenShift IngressController HA intent;
- route sharding for the MayaBanque public frontdoor;
- public exposure of API Gateway and Keycloak only;
- TLS policy at the edge and between router and Keycloak;
- DNS and certificate contracts;
- router/load-balancer health-check expectations;
- failure tests for router pod, worker, zone and external entry point.

C5 does not own:

- application pod HA — C1;
- PostgreSQL HA — C2;
- Redpanda HA — C3;
- Keycloak server/database HA — C4;
- business RTO/RPO acceptance thresholds — C6;
- multi-site/PRA — C7.

## Current CRC model

The V6/CRC base contains OpenShift Routes for:

- `api-gateway`;
- `keycloak`;
- `jaeger`;
- `prometheus`;
- `grafana`.

Those Routes are convenient for the local lab. They are not the V7 production security boundary.

For preproduction/production, C5 exposes only the business/API and IAM frontdoors:

```text
Public north-south
  -> API Gateway
  -> Keycloak

Not public by default
  -> payment-service
  -> consumer-psp
  -> event-audit-service
  -> PostgreSQL
  -> Redpanda
  -> Jaeger
  -> Prometheus
  -> Grafana
```

Administrative observability access must use a separate controlled access pattern (for example corporate access, bastion/VPN, dedicated internal ingress or SSO) and is outside this public frontdoor.

## OpenShift IngressController target

C5 uses a dedicated IngressController shard selected by a Route label rather than relying on every Route being served by the default router.

Reference selector:

```yaml
routeSelector:
  matchLabels:
    ingress.mayabanque.io/shard: public
```

Environment-specific overlays may use distinct values such as `preprod` and `prod` when the environments share a cluster.

### Replica target

Preproduction target:

```text
2 router replicas
```

Production target:

```text
3 router replicas
```

Router replicas must not be interpreted as external load-balancer HA by themselves. The complete path is:

```text
DNS
  -> external load balancer / platform publication
      -> OpenShift router replicas
          -> application Route
              -> Service
                  -> application pods
```

Each layer must be validated independently.

### Failure-domain placement

The IngressController must run on multiple eligible workers/failure domains. The exact node labels and tolerations are environment decisions because this repository does not know whether the target cluster uses dedicated infra nodes, worker nodes or provider-specific topology.

C5 therefore does not invent a `nodeSelector` such as a non-existent `node-role.kubernetes.io/infra` label.

Runtime acceptance requires proving that router replicas are actually distributed across the intended worker/zone topology.

## Endpoint publishing strategy

The `IngressController.spec.endpointPublishingStrategy` is deliberately not hard-coded in the provider-neutral scaffold.

The platform team must choose and validate one strategy appropriate to the real cluster, for example:

- `LoadBalancerService` on supported cloud/platform integrations;
- `HostNetwork` where external infrastructure load-balances directly to router nodes;
- `NodePortService` when the external load balancer targets NodePorts;
- another supported platform-specific design.

The selected publication strategy becomes an environment prerequisite and must be recorded with the runtime evidence.

C5 must not infer that a `LoadBalancerService` object means the external load balancer itself is multi-zone, monitored or resilient.

## DNS contract

C5 does not commit a fictitious production domain.

Each environment must provide real values for at least:

```text
API_GATEWAY_PUBLIC_HOST
KEYCLOAK_PUBLIC_HOST
INGRESS_PUBLIC_DOMAIN
```

DNS requirements:

- public names resolve only to the approved frontdoor;
- TTL is chosen against the failover design rather than arbitrarily;
- DNS records and load-balancer health behavior are documented together;
- DNS failover is tested if DNS participates in the failure strategy;
- no backend Service/Pod address is published directly.

The IngressController domain is immutable after creation, so the real domain must be decided before applying an environment-specific IngressController manifest that sets it.

## TLS certificate contract

No private key or TLS Secret manifest belongs in Git.

Production certificates must come from the approved PKI/certificate lifecycle and be injected into the environment by an approved secret-management process.

Minimum certificate controls:

- SANs match the real public hostnames;
- certificate chain trusted by intended clients;
- private keys remain outside Git;
- expiration monitoring exists;
- renewal/rotation is tested without avoidable outage;
- TLS policy is checked against organization security requirements.

## API Gateway Route

The API Gateway is the only public business API entry point.

Reference route behavior:

```text
client HTTPS
  -> OpenShift router TLS termination
      -> api-gateway Service
```

C5 uses an HTTPS Route with HTTP-to-HTTPS redirect. The exact certificate can be route-specific or supplied by the selected IngressController/default-certificate policy.

No Route is created for `payment-service`, `consumer-psp`, `event-audit-service` or the mocks in the production frontdoor.

## Keycloak Route — re-encrypt target

Keycloak uses a re-encrypt pattern:

```text
client HTTPS
  -> OpenShift router
      -> HTTPS
          -> Keycloak Service
              -> Keycloak pods
```

The router-to-Keycloak hop must therefore terminate on the Keycloak HTTPS endpoint, not on the existing HTTP-only C4 contract.

C5 adds an internal service-serving certificate contract for the operator-managed `keycloak` Service. The certificate Secret is generated/provisioned in the cluster and is referenced by the Keycloak CR; its contents are never committed.

The C4 compatibility endpoint remains available internally while migration is incomplete:

```text
http://keycloak:8080
```

Existing Quarkus resource servers therefore do not need a Java rebuild merely for the C5 external frontdoor change. A later security hardening iteration may switch internal OIDC discovery to HTTPS separately.

### Keycloak public hostname

The Keycloak public hostname cannot be invented in the generic repository target. Before runtime deployment, the environment-specific configuration must set the real Keycloak hostname and proxy/header contract consistently with the Route/LB.

C5 acceptance must verify:

- OIDC discovery advertises the real HTTPS issuer;
- token issuer is stable across router/pod failures;
- JWK endpoint is reachable through the public path;
- redirect URIs do not fall back to internal service DNS;
- forwarded-header handling cannot be spoofed from untrusted sources.

## Route sharding

Only C5 public routes receive the shard label, for example:

```yaml
metadata:
  labels:
    ingress.mayabanque.io/shard: public
```

The dedicated IngressController uses the matching `routeSelector`.

The target must verify that unrelated lab/admin Routes are not admitted by the public shard.

## NetworkPolicy boundary

C5 must prevent arbitrary namespace workloads from spoofing a trusted reverse proxy path to Keycloak when forwarded headers are enabled.

The runtime design should allow Keycloak HTTPS ingress only from the selected OpenShift ingress/router path plus any explicitly required monitoring/management sources.

The exact namespace/pod labels used by the platform ingress deployment must be verified on the real cluster before enforcing the final NetworkPolicy. C5 will not guess labels that may differ across platform/operator versions.

## Health checks

Health must be measured at each layer:

### Router

- router replicas Ready;
- router deployment/daemon placement healthy;
- endpoint publication healthy.

### Load balancer

- health check reaches the intended router endpoint;
- unhealthy router/node is removed;
- failover does not depend on manual action.

### API Gateway

- Route reaches gateway readiness/business endpoint;
- no direct backend bypass.

### Keycloak

- public OIDC discovery works;
- token endpoint works;
- re-encrypt backend TLS validates correctly;
- management port `9000` is not exposed as public application traffic.

## Failure scenarios

### C5-F1 — router pod loss

- establish API Gateway and Keycloak baseline;
- delete one router pod;
- verify public traffic continues through another router;
- measure interruption/RTO.

### C5-F2 — router worker loss

On a real multi-worker cluster:

- fail the worker carrying one router replica;
- verify external LB removes/avoids the failed endpoint;
- verify surviving router capacity;
- verify replacement scheduling;
- measure API/OIDC interruption.

### C5-F3 — router zone loss

On a real multi-zone environment:

- fail one router failure domain;
- verify DNS/LB still reaches surviving zone(s);
- verify API Gateway and Keycloak routes;
- measure RTO/error rate.

### C5-F4 — load-balancer target loss

- remove/disable one LB backend target;
- verify health-check removal and continued service;
- confirm no stale target causes a long black-hole interval.

### C5-F5 — certificate rotation

- rotate the selected ingress/route certificate in non-production;
- verify clients continue to trust the new chain;
- verify Keycloak re-encrypt remains healthy;
- record any interruption.

### C5-F6 — DNS change/failover

If DNS participates in failover:

- change/fail the active frontdoor target according to the runbook;
- measure effective resolver/client convergence;
- distinguish DNS TTL delay from load-balancer/router RTO.

## Evidence to capture

```text
IngressController spec/status
router pods and node/zone placement
endpointPublishingStrategy actually used
external LB health/backends
public DNS records and TTL
certificate issuer/SAN/expiry (never private key)
API Gateway HTTPS result
Keycloak OIDC discovery/token/JWK result
failure timestamp
first successful request after failure
observed RTO/error window
```

## Implementation sequence

1. **C5-A — architecture decision** — this document.
2. **C5-B — provider-neutral IngressController shard scaffold**.
3. **C5-C — application public Route component (API Gateway + Keycloak)**.
4. **C5-D — preprod/prod integration and removal of lab/admin public Routes**.
5. **C5-E — Keycloak backend TLS/re-encrypt contract**.
6. **C5-F — CI render/security gates**.
7. **C5-G — runtime failure labs/evidence on a suitable environment**.
8. **C5-H — map measured evidence to C6 RTO/RPO acceptance criteria**.

## Evidence boundary

Git/render validation can prove that the desired-state model contains the intended resources and excludes obvious lab exposures/secrets.

It cannot prove:

- external load-balancer implementation or multi-zone resilience;
- public DNS control-plane availability;
- real certificate trust/renewal;
- router worker/zone failover;
- Keycloak login/session continuity through the complete external path;
- production RTO/RPO;
- site-level disaster recovery.

Those remain runtime gates on an appropriate environment.
