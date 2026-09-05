#!/usr/bin/env bash
set -euo pipefail

: "${ALICE_TOKEN:?Set ALICE_TOKEN before running this test}"
: "${AUDITOR_TOKEN:?Set AUDITOR_TOKEN before running this test}"
: "${SCA_CODE:?Set SCA_CODE before running this test}"

PROJECT=wero-poc
GITOPS_NS=openshift-gitops
APP=wero-poc-crc
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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
MANAGED="$(oc get deployment api-gateway -n "$PROJECT" -o jsonpath='{.metadata.annotations.gitops\.mayabanque\.io/managed-by}')"
ENVIRONMENT="$(oc get deployment api-gateway -n "$PROJECT" -o jsonpath='{.metadata.annotations.gitops\.mayabanque\.io/environment}')"
[[ "$MANAGED" == "argocd" ]]
[[ "$ENVIRONMENT" == "crc" ]]
! grep -R -E '^[[:space:]]*kind:[[:space:]]*Secret[[:space:]]*$' "$ROOT/gitops" >/dev/null

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

echo "==> 7. V4 business + observability regression through GitOps deployment"
"$ROOT/tests/e2e/test-v4-observability.sh"

echo "V5 OK: Git/Kustomize -> OpenShift GitOps/Argo CD -> automated sync/prune/self-heal, secrets outside Git, V4 payment and observability regression successful."
