#!/usr/bin/env bash
set -euo pipefail

: "${ALICE_TOKEN:?Set ALICE_TOKEN before running this test}"
: "${AUDITOR_TOKEN:?Set AUDITOR_TOKEN before running this test}"
: "${SCA_CODE:?Set SCA_CODE before running this test}"

PROJECT=wero-poc
GITOPS_NS=openshift-gitops
APP=wero-poc-crc
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

service_backend_addresses() {
  local service_name="$1"
  local addresses=""

  # Prefer EndpointSlice (current Kubernetes API). Some CRC/OpenShift client
  # combinations can expose an empty result through the short resource alias,
  # so use the fully-qualified resource first and fall back to legacy Endpoints.
  addresses="$(oc get endpointslices.discovery.k8s.io -n "$PROJECT" \
    -l "kubernetes.io/service-name=${service_name}" \
    -o jsonpath='{range .items[*].endpoints[*]}{range .addresses[*]}{.}{" "}{end}{end}' \
    2>/dev/null || true)"

  if [[ -z "${addresses// /}" ]]; then
    addresses="$(oc get endpoints "$service_name" -n "$PROJECT" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  fi

  printf '%s' "$addresses"
}

echo "==> 1. OpenShift GitOps / Argo CD is installed"
oc get subscription openshift-gitops-operator -n openshift-operators >/dev/null
oc get deployment openshift-gitops-server -n "$GITOPS_NS" >/dev/null
oc get route openshift-gitops-server -n "$GITOPS_NS" >/dev/null

echo "==> 2. Wero Application is Synced and Healthy"
SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}')"
HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}')"
echo "sync=$SYNC health=$HEALTH"
[[ "$SYNC" == "Synced" ]]
[[ "$HEALTH" == "Healthy" ]]

echo "==> 3. Runtime desired state comes from Git/Kustomize"
MANAGED="$(oc get deployment api-gateway -n "$PROJECT" -o jsonpath='{.metadata.annotations.gitops\\.mayabanque\\.io/managed-by}')"
ENVIRONMENT="$(oc get deployment api-gateway -n "$PROJECT" -o jsonpath='{.metadata.annotations.gitops\\.mayabanque\\.io/environment}')"
[[ "$MANAGED" == "argocd" ]]
[[ "$ENVIRONMENT" == "crc" ]]
! grep -R -E '^[[:space:]]*kind:[[:space:]]*Secret[[:space:]]*$' "$ROOT/gitops/base" "$ROOT/gitops/overlays" >/dev/null

echo "==> 4. Public routes and V3B backend isolation are still enforced"
oc get route api-gateway keycloak jaeger prometheus grafana -n "$PROJECT" >/dev/null
! oc get route payment-service -n "$PROJECT" >/dev/null 2>&1
! oc get route event-audit-service -n "$PROJECT" >/dev/null 2>&1
oc get networkpolicy gateway-only-payment gateway-only-audit -n "$PROJECT" >/dev/null

echo "==> 5. All Git-managed workloads are available"
for d in postgresql kafka keycloak jaeger prometheus grafana api-gateway payment-service consumer-psp event-audit-service mock-wero mock-sct-inst; do
  READY="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.status.readyReplicas}')"
  [[ "${READY:-0}" -ge 1 ]] || { echo "$d is not ready"; exit 1; }
done

echo "==> 6. Drift detection + automatic self-heal"
ORIGINAL="$(oc get deployment api-gateway -n "$PROJECT" -o jsonpath='{.spec.replicas}')"
[[ "$ORIGINAL" == "1" ]] || { echo "Expected api-gateway replicas=1, got $ORIGINAL"; exit 1; }
oc patch deployment api-gateway -n "$PROJECT" --type=merge -p '{"spec":{"replicas":2}}' >/dev/null
[[ "$(oc get deployment api-gateway -n "$PROJECT" -o jsonpath='{.spec.replicas}')" == "2" ]]
oc annotate application "$APP" -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null

HEALED=false
for _ in $(seq 1 36); do
  REPLICAS="$(oc get deployment api-gateway -n "$PROJECT" -o jsonpath='{.spec.replicas}')"
  SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  if [[ "$REPLICAS" == "1" && "$SYNC" == "Synced" ]]; then
    HEALED=true
    break
  fi
  sleep 5
done
[[ "$HEALED" == "true" ]] || {
  echo "Argo CD did not self-heal api-gateway replicas back to 1"
  oc get application "$APP" -n "$GITOPS_NS"
  oc get deployment api-gateway -n "$PROJECT"
  exit 1
}
echo "api-gateway drift healed back to replicas=1"

# Synced/Healthy proves desired-state convergence. Before the V4 HTTP
# regression, also prove the healed gateway is actually routable.
echo "==> 6b. Gateway dataplane is ready after self-heal"
oc rollout status deployment/api-gateway -n "$PROJECT" --timeout=180s >/dev/null
SERVICE_APP_SELECTOR="$(oc get service api-gateway -n "$PROJECT" -o jsonpath='{.spec.selector.app}' 2>/dev/null || true)"
SERVICE_LEGACY_SELECTOR="$(oc get service api-gateway -n "$PROJECT" -o jsonpath='{.spec.selector.deployment}' 2>/dev/null || true)"
[[ "$SERVICE_APP_SELECTOR" == "api-gateway" && -z "$SERVICE_LEGACY_SELECTOR" ]] || {
  echo "api-gateway Service selector is not exactly app=api-gateway"
  oc get service api-gateway -n "$PROJECT" -o jsonpath='{.spec.selector}{"\n"}'
  exit 1
}

GATEWAY_HOST="$(oc get route api-gateway -n "$PROJECT" -o jsonpath='{.spec.host}')"
DATAPLANE_READY=false
ENDPOINT_IPS=""
HTTP_CODE=""
for _ in $(seq 1 36); do
  ENDPOINT_IPS="$(service_backend_addresses api-gateway)"
  HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "http://${GATEWAY_HOST}/health/ready" 2>/dev/null || true)"
  if [[ -n "${ENDPOINT_IPS// /}" && "$HTTP_CODE" == "200" ]]; then
    DATAPLANE_READY=true
    break
  fi
  sleep 5
done
[[ "$DATAPLANE_READY" == "true" ]] || {
  echo "api-gateway dataplane did not become ready after self-heal"
  echo "Backend addresses: ${ENDPOINT_IPS:-<none>}"
  echo "Route health HTTP: ${HTTP_CODE:-<none>}"
  exit 1
}
echo "api-gateway backend + Route ready (HTTP 200)"

echo "==> 7. V4 business + observability regression through GitOps deployment"
"$ROOT/tests/e2e/test-v4-observability.sh"

echo "V5 OK: Git/Kustomize -> OpenShift GitOps/Argo CD -> automated sync/prune/self-heal, secrets outside Git, V4 payment and observability regression successful."
