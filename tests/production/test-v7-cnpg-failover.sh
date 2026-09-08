#!/usr/bin/env bash
set -euo pipefail

# V7 C2 production/preproduction lab: CloudNativePG primary-pod failover.
# This script is intentionally NOT a CRC test. Run it only on an environment
# with the CNPG operator installed and the mayabank-postgresql Cluster healthy.
# It does not read or print database credentials.

NAMESPACE="${1:-wero-poc-preprod}"
CLUSTER="${2:-mayabank-postgresql}"
TIMEOUT_SECONDS="${FAILOVER_TIMEOUT_SECONDS:-300}"

if [[ "${CONFIRM_CNPG_FAILOVER:-}" != "yes" ]]; then
  echo "Refusing destructive failover test. Set CONFIRM_CNPG_FAILOVER=yes explicitly."
  exit 2
fi

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc CLI is required"; exit 1; }

cluster_resource="cluster.postgresql.cnpg.io/${CLUSTER}"
oc get "${cluster_resource}" -n "${NAMESPACE}" >/dev/null

get_primary() {
  oc get pods -n "${NAMESPACE}" \
    -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=primary" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -n1
}

OLD_PRIMARY="$(get_primary)"
[[ -n "${OLD_PRIMARY}" ]] || { echo "ERROR: no CNPG primary pod found"; exit 1; }

INSTANCE_COUNT="$(oc get pods -n "${NAMESPACE}" -l "cnpg.io/cluster=${CLUSTER}" -o name | wc -l | tr -d ' ')"
[[ "${INSTANCE_COUNT}" -eq 3 ]] || {
  echo "ERROR: expected 3 CNPG instance pods before failover, got ${INSTANCE_COUNT}"
  exit 1
}

oc wait --for=condition=Ready pod -n "${NAMESPACE}" \
  -l "cnpg.io/cluster=${CLUSTER}" --timeout="${TIMEOUT_SECONDS}s" >/dev/null

echo "C2-F1 baseline: namespace=${NAMESPACE} cluster=${CLUSTER} instances=${INSTANCE_COUNT} primary=${OLD_PRIMARY}"

START_EPOCH="$(date +%s)"
oc delete pod "${OLD_PRIMARY}" -n "${NAMESPACE}" --wait=false >/dev/null

echo "C2-F1 fault injected: deleted primary pod ${OLD_PRIMARY}"

DEADLINE=$((START_EPOCH + TIMEOUT_SECONDS))
NEW_PRIMARY=""
while (( $(date +%s) <= DEADLINE )); do
  CANDIDATE="$(get_primary || true)"
  if [[ -n "${CANDIDATE}" && "${CANDIDATE}" != "${OLD_PRIMARY}" ]]; then
    if oc get pod "${CANDIDATE}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q '^True$'; then
      NEW_PRIMARY="${CANDIDATE}"
      break
    fi
  fi
  sleep 2
done

[[ -n "${NEW_PRIMARY}" ]] || {
  echo "ERROR: no different Ready CNPG primary was elected within ${TIMEOUT_SECONDS}s"
  exit 1
}

PROMOTION_EPOCH="$(date +%s)"
RTO_SECONDS=$((PROMOTION_EPOCH - START_EPOCH))

# The CNPG RW service must converge on the promoted primary. EndpointSlice is
# preferred over the legacy Endpoints API.
RW_SERVICE="${CLUSTER}-rw"
RW_TARGETS="$(oc get endpointslice -n "${NAMESPACE}" \
  -l "kubernetes.io/service-name=${RW_SERVICE}" \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -u)"

printf '%s\n' "${RW_TARGETS}" | grep -qx "${NEW_PRIMARY}" || {
  echo "ERROR: RW service ${RW_SERVICE} does not target promoted primary ${NEW_PRIMARY}"
  echo "Observed RW targets:"
  printf '%s\n' "${RW_TARGETS}"
  exit 1
}

oc wait --for=condition=Ready pod -n "${NAMESPACE}" \
  -l "cnpg.io/cluster=${CLUSTER}" --timeout="${TIMEOUT_SECONDS}s" >/dev/null

FINAL_INSTANCE_COUNT="$(oc get pods -n "${NAMESPACE}" -l "cnpg.io/cluster=${CLUSTER}" -o name | wc -l | tr -d ' ')"
FINAL_PRIMARY_COUNT="$(oc get pods -n "${NAMESPACE}" \
  -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=primary" -o name | wc -l | tr -d ' ')"

[[ "${FINAL_INSTANCE_COUNT}" -eq 3 ]] || { echo "ERROR: cluster did not return to 3 instance pods"; exit 1; }
[[ "${FINAL_PRIMARY_COUNT}" -eq 1 ]] || { echo "ERROR: expected exactly one primary, got ${FINAL_PRIMARY_COUNT}"; exit 1; }

echo "C2-F1 OK: oldPrimary=${OLD_PRIMARY} newPrimary=${NEW_PRIMARY} rwService=${RW_SERVICE} promotionRTO=${RTO_SECONDS}s finalInstances=${FINAL_INSTANCE_COUNT} primaryCount=${FINAL_PRIMARY_COUNT}"
echo "Boundary: this proves CNPG pod-level primary promotion/service convergence only. It does not prove business RPO, zone-loss HA, backup restore, PITR, or a production SLA."
