#!/usr/bin/env bash
set -euo pipefail

# C6 evidence evaluator. It is non-destructive and can be run after C1-C5/C7
# experiments. Only supplied observations are evaluated; missing observations
# are reported as SKIP and never fabricated.

failures=0
checks=0

check_max() {
  local name="$1" observed="$2" target="$3" unit="${4:-s}"
  if [[ -z "${observed}" ]]; then
    echo "SKIP ${name}: no observation supplied"
    return 0
  fi
  [[ "${observed}" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR ${name}: non-numeric observation '${observed}'"; failures=$((failures+1)); return; }
  checks=$((checks+1))
  awk -v o="${observed}" -v t="${target}" 'BEGIN { exit !(o <= t) }' \
    && echo "PASS ${name}: ${observed}${unit} <= ${target}${unit}" \
    || { echo "FAIL ${name}: ${observed}${unit} > ${target}${unit}"; failures=$((failures+1)); }
}

check_zero() {
  local name="$1" observed="$2"
  if [[ -z "${observed}" ]]; then
    echo "SKIP ${name}: no observation supplied"
    return 0
  fi
  [[ "${observed}" =~ ^[0-9]+$ ]] || { echo "ERROR ${name}: non-integer observation '${observed}'"; failures=$((failures+1)); return; }
  checks=$((checks+1))
  [[ "${observed}" -eq 0 ]] \
    && echo "PASS ${name}: 0" \
    || { echo "FAIL ${name}: expected 0, got ${observed}"; failures=$((failures+1)); }
}

check_max "public-api-rto" "${PUBLIC_API_RTO_SECONDS:-}" 60
check_max "payment-db-rto" "${PAYMENT_DB_RTO_SECONDS:-}" 60
check_max "redpanda-service-rto" "${REDPANDA_RTO_SECONDS:-}" 120
check_max "audit-convergence-rto" "${AUDIT_CONVERGENCE_SECONDS:-}" 300
check_max "iam-new-token-rto" "${IAM_RTO_SECONDS:-}" 120
check_max "frontdoor-rto" "${FRONTDOOR_RTO_SECONDS:-}" 60
check_max "site-rto" "${SITE_RTO_SECONDS:-}" 1800
check_max "site-rpo" "${SITE_RPO_SECONDS:-}" 300

check_zero "duplicate-rail-rows" "${DUPLICATE_RAIL_ROWS:-}"
check_zero "duplicate-settlement-ledger" "${DUPLICATE_SETTLEMENT_LEDGER_ROWS:-}"
check_zero "lost-committed-payment-rows" "${LOST_COMMITTED_PAYMENT_ROWS:-}"

if [[ "${checks}" -eq 0 ]]; then
  echo "C6 evidence evaluator: no observations supplied; syntax/readiness only."
  exit 0
fi

if [[ "${failures}" -ne 0 ]]; then
  echo "C6 evidence FAILED: checks=${checks} failures=${failures}"
  exit 1
fi

echo "C6 evidence OK: checks=${checks} failures=0"
echo "Boundary: passing supplied measurements does not create a contractual SLA; retain raw test evidence and environment metadata."
