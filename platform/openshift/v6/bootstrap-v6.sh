#!/usr/bin/env bash
set -euo pipefail

PROJECT="wero-poc"
GITOPS_NS="openshift-gitops"
APP="wero-poc-crc"
TARGET_REVISION="v6-spof-chaos-ha-resilience"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

command -v oc >/dev/null || { echo "oc is required"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "Log in to OpenShift first"; exit 1; }

if ! oc auth can-i update applications.argoproj.io -n "$GITOPS_NS" | grep -q '^yes$'; then
  echo "Current OpenShift session cannot update Argo CD Applications in ${GITOPS_NS}."
  echo "Use the same cluster-admin session used for the V5 bootstrap."
  exit 1
fi

echo "==> 1. Point Argo CD to the V6 branch"
oc apply -f "$ROOT/gitops/argocd/project.yaml" >/dev/null
oc apply -f "$ROOT/gitops/argocd/application.yaml" >/dev/null
oc annotate application "$APP" -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null

ACTUAL_REVISION="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.spec.source.targetRevision}')"
[[ "$ACTUAL_REVISION" == "$TARGET_REVISION" ]] || {
  echo "Expected Argo targetRevision=${TARGET_REVISION}, got ${ACTUAL_REVISION}"
  exit 1
}

echo "==> 2. Wait for V6 desired state to converge"
READY=false
for _ in $(seq 1 60); do
  SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    READY=true
    break
  fi
  sleep 5
done
[[ "$READY" == "true" ]] || {
  echo "Argo CD did not reach Synced/Healthy"
  oc get application "$APP" -n "$GITOPS_NS"
  exit 1
}
echo "sync=Synced health=Healthy"

echo "==> 3. Verify stateless N+1 baseline"
for d in api-gateway payment-service consumer-psp event-audit-service mock-wero mock-sct-inst; do
  DESIRED="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.spec.replicas}')"
  [[ "$DESIRED" == "2" ]] || { echo "$d expected replicas=2, got $DESIRED"; exit 1; }
  oc rollout status deployment/"$d" -n "$PROJECT" --timeout=240s >/dev/null
  READY_REPLICAS="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.status.readyReplicas}')"
  [[ "${READY_REPLICAS:-0}" -ge 2 ]] || { echo "$d readyReplicas=${READY_REPLICAS:-0}"; exit 1; }
done

echo "==> 4. Verify disruption budgets"
for p in api-gateway payment-service consumer-psp event-audit-service mock-wero mock-sct-inst; do
  MIN_AVAILABLE="$(oc get pdb "$p" -n "$PROJECT" -o jsonpath='{.spec.minAvailable}')"
  [[ "$MIN_AVAILABLE" == "1" ]] || { echo "$p PDB minAvailable expected 1, got $MIN_AVAILABLE"; exit 1; }
done

echo "V6 bootstrap OK: Argo CD now reconciles the V6 branch with two stateless replicas and PDB minAvailable=1."
