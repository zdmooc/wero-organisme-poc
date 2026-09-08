#!/usr/bin/env bash
set -euo pipefail

# Non-destructive C7 readiness check. It never promotes, deletes or fails over
# resources. It only verifies that two contexts expose the expected building blocks.

PRIMARY_CONTEXT="${PRIMARY_CONTEXT:-}"
DR_CONTEXT="${DR_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-wero-poc-prod}"

if [[ -z "${PRIMARY_CONTEXT}" || -z "${DR_CONTEXT}" ]]; then
  echo "C7 DR readiness: set PRIMARY_CONTEXT and DR_CONTEXT to run against real clusters."
  echo "No infrastructure supplied; readiness script syntax is valid and no action was taken."
  exit 0
fi

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc CLI required"; exit 1; }

check_context() {
  local ctx="$1" role="$2"
  echo "Checking ${role}: ${ctx}"
  oc --context "${ctx}" get namespace "${NAMESPACE}" >/dev/null
  oc --context "${ctx}" get cluster.postgresql.cnpg.io -n "${NAMESPACE}" >/dev/null
  oc --context "${ctx}" get redpanda.cluster.redpanda.com -n "${NAMESPACE}" >/dev/null
  oc --context "${ctx}" get keycloak.k8s.keycloak.org -n "${NAMESPACE}" >/dev/null
  oc --context "${ctx}" get deployment -n "${NAMESPACE}" >/dev/null
}

check_context "${PRIMARY_CONTEXT}" PRIMARY
check_context "${DR_CONTEXT}" DR

if [[ "${PRIMARY_CONTEXT}" == "${DR_CONTEXT}" ]]; then
  echo "ERROR: PRIMARY_CONTEXT and DR_CONTEXT must be distinct for a C7 proof."
  exit 1
fi

echo "C7 DR readiness OK: both contexts expose expected resource APIs."
echo "Boundary: this is not a failover test and proves neither replication, fencing, RTO nor RPO."
