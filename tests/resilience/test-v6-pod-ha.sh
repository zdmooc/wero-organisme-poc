#!/usr/bin/env bash
set -euo pipefail

PROJECT="wero-poc"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATELESS=(api-gateway payment-service consumer-psp event-audit-service mock-wero)
STATEFUL_SPOF=(postgresql kafka keycloak mock-sct-inst)

echo "==> 1. V5 regression on the V6 desired state"
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "==> 2. Verify V6 stateless HA baseline"
for d in "${STATELESS[@]}"; do
  DESIRED="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.spec.replicas}')"
  READY="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.status.readyReplicas}')"
  [[ "$DESIRED" == "2" ]] || { echo "$d expected desired replicas=2, got $DESIRED"; exit 1; }
  [[ "${READY:-0}" -ge 2 ]] || { echo "$d expected ready replicas>=2, got ${READY:-0}"; exit 1; }

  MIN_AVAILABLE="$(oc get pdb "$d" -n "$PROJECT" -o jsonpath='{.spec.minAvailable}')"
  [[ "$MIN_AVAILABLE" == "1" ]] || { echo "$d PDB expected minAvailable=1, got $MIN_AVAILABLE"; exit 1; }
done

[[ "$(oc get deployment mock-sct-inst -n "$PROJECT" -o jsonpath='{.spec.replicas}')" == "1" ]] || {
  echo "mock-sct-inst must remain a single-replica stateful SPOF until settlement state is externalized"
  exit 1
}

echo "==> 3. Kill one pod per truly stateless component and measure recovery"
for d in "${STATELESS[@]}"; do
  POD="$(oc get pods -n "$PROJECT" -l "app=${d}" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$POD" ]] || { echo "No running pod found for $d"; exit 1; }

  START="$(date +%s)"
  echo "chaos: deleting $POD from deployment/$d"
  oc delete pod "$POD" -n "$PROJECT" --wait=false >/dev/null

  SURVIVOR=false
  for _ in $(seq 1 30); do
    OLD_EXISTS="$(oc get pod "$POD" -n "$PROJECT" --ignore-not-found -o name 2>/dev/null || true)"
    READY="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ -z "$OLD_EXISTS" && "${READY:-0}" -ge 1 ]]; then
      SURVIVOR=true
      break
    fi
    sleep 1
  done
  [[ "$SURVIVOR" == "true" ]] || {
    echo "$d lost all ready replicas after pod deletion"
    oc get pods -n "$PROJECT" -l "app=${d}" -o wide
    exit 1
  }

  oc rollout status deployment/"$d" -n "$PROJECT" --timeout=240s >/dev/null
  READY="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.status.readyReplicas}')"
  [[ "${READY:-0}" -ge 2 ]] || { echo "$d did not recover to two ready replicas"; exit 1; }
  ELAPSED="$(( $(date +%s) - START ))"
  echo "$d recovered to 2 ready replicas in ${ELAPSED}s; at least one replica remained ready"
done

echo "==> 4. Record stateful SPOFs without destructive failover claims"
for d in "${STATEFUL_SPOF[@]}"; do
  REPLICAS="$(oc get deployment "$d" -n "$PROJECT" -o jsonpath='{.spec.replicas}')"
  [[ "$REPLICAS" == "1" ]] || { echo "$d expected single-replica SPOF baseline, got $REPLICAS"; exit 1; }
  echo "KNOWN SPOF: $d replicas=1"
done

echo "==> 5. Full business/observability regression after chaos"
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "V6 OK (phase A): five truly stateless components survived one-pod loss and recovered to two replicas; V5 business/observability regression still passes. PostgreSQL, Kafka, Keycloak and the in-memory mock-sct-inst remain explicit single-replica SPOFs for the next V6 phase."
