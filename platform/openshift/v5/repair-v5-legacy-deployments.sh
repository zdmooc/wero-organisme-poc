#!/usr/bin/env bash
set -euo pipefail

PROJECT="wero-poc"
GITOPS_NS="openshift-gitops"
APP_NAME="wero-poc-crc"
DEPLOYMENTS=(
  api-gateway
  payment-service
  consumer-psp
  event-audit-service
  mock-wero
  mock-sct-inst
)

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc is required"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "ERROR: login to OpenShift first"; exit 1; }

oc get application "$APP_NAME" -n "$GITOPS_NS" >/dev/null 2>&1 || {
  echo "ERROR: Argo CD Application $APP_NAME not found in $GITOPS_NS"
  exit 1
}

echo "==> Inspecting legacy V3/V4 Deployment selectors"
RECREATED=0
for d in "${DEPLOYMENTS[@]}"; do
  if ! oc get deployment "$d" -n "$PROJECT" >/dev/null 2>&1; then
    echo "==> $d is absent; Argo CD will create it"
    continue
  fi

  APP_SELECTOR="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null || true)"
  LEGACY_SELECTOR="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.spec.selector.matchLabels.deployment}' 2>/dev/null || true)"
  echo "    $d selector.app=${APP_SELECTOR:-<none>} selector.deployment=${LEGACY_SELECTOR:-<none>}"

  # Deployments originally created by `oc new-app` can retain an immutable
  # `deployment=<name>` selector. V5 Git declares `app=<name>`. Argo CD cannot
  # patch Deployment selectors because the field is immutable, so the only
  # correct migration is a one-time recreate of the Deployment. Services,
  # Secrets, PVCs, Routes and data are left untouched.
  if [[ "$APP_SELECTOR" != "$d" ]]; then
    echo "==> Recreating legacy Deployment $d for GitOps ownership"
    oc delete deployment "$d" -n "$PROJECT" --wait=true
    RECREATED=$((RECREATED + 1))
  fi
done

echo "==> Requesting hard Argo CD refresh"
oc annotate application "$APP_NAME" -n "$GITOPS_NS" \
  argocd.argoproj.io/refresh=hard --overwrite >/dev/null

# Automated self-heal should recreate every deleted Deployment from Git.
echo "==> Waiting for GitOps recreation and convergence"
for d in "${DEPLOYMENTS[@]}"; do
  for _ in $(seq 1 72); do
    if oc get deployment "$d" -n "$PROJECT" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  oc get deployment "$d" -n "$PROJECT" >/dev/null 2>&1 || {
    echo "ERROR: $d was not recreated by Argo CD"
    exit 1
  }
  oc rollout status deployment/"$d" -n "$PROJECT" --timeout=360s

  APP_SELECTOR="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null || true)"
  [[ "$APP_SELECTOR" == "$d" ]] || {
    echo "ERROR: $d selector is still not app=$d"
    oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.spec.selector.matchLabels}{"\n"}'
    exit 1
  }
done

SYNCED=false
for _ in $(seq 1 72); do
  SYNC="$(oc get application "$APP_NAME" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH="$(oc get application "$APP_NAME" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  printf '\rArgo CD: sync=%-10s health=%-12s' "${SYNC:-Unknown}" "${HEALTH:-Unknown}"
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    SYNCED=true
    echo
    break
  fi
  sleep 5
done

if [[ "$SYNCED" != "true" ]]; then
  echo
  echo "ERROR: Application is still not Synced/Healthy"
  oc get application "$APP_NAME" -n "$GITOPS_NS" \
    -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}{.kind}{"/"}{.name}{"  health="}{.health.status}{"\n"}{end}'
  exit 1
fi

echo "V5 migration repair OK: $RECREATED legacy Deployment(s) recreated; Argo CD is Synced/Healthy."
