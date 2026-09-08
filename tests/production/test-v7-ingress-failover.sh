#!/usr/bin/env bash
set -euo pipefail

# V7 C5-F1 — router pod loss / public frontdoor continuity.
#
# This test requires a real OpenShift environment where the C5 frontdoor has
# been instantiated with real DNS, certificates and an endpoint publication
# strategy. It is intentionally not a CRC HA proof.
#
# Required:
#   INGRESS_CONTROLLER        e.g. mayabank-preprod-public
#   API_GATEWAY_PUBLIC_HOST   real DNS host, no scheme
#   KEYCLOAK_PUBLIC_HOST      real DNS host, no scheme
#
# Optional:
#   ROUTER_NAMESPACE          default: openshift-ingress
#   ROUTER_DEPLOYMENT         default: router-${INGRESS_CONTROLLER}
#   ROUTER_POD_SELECTOR       default: ingresscontroller.operator.openshift.io/deployment-ingresscontroller=${INGRESS_CONTROLLER}
#   KEYCLOAK_REALM            default: mayabanque
#   MAX_RTO_SECONDS           default: 120
#   POLL_SECONDS              default: 1
#   CURL_CA_BUNDLE            optional CA bundle understood by curl
#
# Destructive gate:
#   ALLOW_DESTRUCTIVE_C5=true
#
# The test deletes ONE router pod only. Worker/zone/LB/DNS/certificate failure
# scenarios C5-F2..F6 require environment-specific runbooks and are not faked
# here.

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: required environment variable $name is not set" >&2
    exit 2
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $cmd" >&2
    exit 2
  }
}

require_env INGRESS_CONTROLLER
require_env API_GATEWAY_PUBLIC_HOST
require_env KEYCLOAK_PUBLIC_HOST
require_cmd oc
require_cmd curl

ROUTER_NAMESPACE="${ROUTER_NAMESPACE:-openshift-ingress}"
ROUTER_DEPLOYMENT="${ROUTER_DEPLOYMENT:-router-${INGRESS_CONTROLLER}}"
ROUTER_POD_SELECTOR="${ROUTER_POD_SELECTOR:-ingresscontroller.operator.openshift.io/deployment-ingresscontroller=${INGRESS_CONTROLLER}}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-mayabanque}"
MAX_RTO_SECONDS="${MAX_RTO_SECONDS:-120}"
POLL_SECONDS="${POLL_SECONDS:-1}"

API_URL="https://${API_GATEWAY_PUBLIC_HOST}/health/ready"
OIDC_URL="https://${KEYCLOAK_PUBLIC_HOST}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration"

check_https() {
  local url="$1"
  curl --fail --silent --show-error --location \
    --connect-timeout 3 --max-time 8 \
    "$url" >/dev/null
}

wait_public_path() {
  local started epoch elapsed api_ok oidc_ok
  started="$(date +%s)"
  while true; do
    api_ok=0
    oidc_ok=0
    check_https "$API_URL" && api_ok=1 || true
    check_https "$OIDC_URL" && oidc_ok=1 || true

    if [[ "$api_ok" -eq 1 && "$oidc_ok" -eq 1 ]]; then
      epoch="$(date +%s)"
      elapsed="$((epoch - started))"
      echo "$elapsed"
      return 0
    fi

    epoch="$(date +%s)"
    elapsed="$((epoch - started))"
    if (( elapsed >= MAX_RTO_SECONDS )); then
      echo "ERROR: public API/OIDC path did not recover within ${MAX_RTO_SECONDS}s" >&2
      return 1
    fi
    sleep "$POLL_SECONDS"
  done
}

echo '=== C5-F1 preconditions ==='
oc whoami >/dev/null
oc get ingresscontroller "$INGRESS_CONTROLLER" -n openshift-ingress-operator -o wide
oc get deployment "$ROUTER_DEPLOYMENT" -n "$ROUTER_NAMESPACE" -o wide

mapfile -t ROUTER_PODS < <(
  oc get pods -n "$ROUTER_NAMESPACE" \
    -l "$ROUTER_POD_SELECTOR" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)

if (( ${#ROUTER_PODS[@]} < 2 )); then
  echo "ERROR: C5-F1 needs at least 2 router pods; found ${#ROUTER_PODS[@]} using selector: $ROUTER_POD_SELECTOR" >&2
  echo 'This is not a valid HA environment for the test.' >&2
  exit 3
fi

oc get pods -n "$ROUTER_NAMESPACE" -l "$ROUTER_POD_SELECTOR" -o wide

if ! check_https "$API_URL"; then
  echo "ERROR: API Gateway baseline is not healthy at $API_URL" >&2
  exit 4
fi
if ! check_https "$OIDC_URL"; then
  echo "ERROR: Keycloak OIDC baseline is not healthy at $OIDC_URL" >&2
  exit 4
fi

echo 'Baseline public API + OIDC: OK'

echo '=== Failure-domain evidence before fault ==='
oc get pods -n "$ROUTER_NAMESPACE" -l "$ROUTER_POD_SELECTOR" \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[*].ready'

if [[ "${ALLOW_DESTRUCTIVE_C5:-false}" != "true" ]]; then
  echo 'DRY-RUN ONLY: no router pod deleted.'
  echo 'Set ALLOW_DESTRUCTIVE_C5=true only on an approved non-production/failure-test environment.'
  exit 0
fi

VICTIM="${ROUTER_PODS[0]}"
FAILURE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=== C5-F1 delete one router pod: $VICTIM at $FAILURE_TS ==="
oc delete pod "$VICTIM" -n "$ROUTER_NAMESPACE" --wait=false

RTO_SECONDS="$(wait_public_path)"
echo "Public API + OIDC first jointly successful check after fault: ${RTO_SECONDS}s"

echo '=== Router state after recovery ==='
oc get pods -n "$ROUTER_NAMESPACE" -l "$ROUTER_POD_SELECTOR" -o wide

if ! oc rollout status deployment/"$ROUTER_DEPLOYMENT" -n "$ROUTER_NAMESPACE" --timeout="${MAX_RTO_SECONDS}s"; then
  echo 'ERROR: router deployment did not return to Ready state within timeout' >&2
  exit 5
fi

echo "C5-F1 OK: one router pod was removed; API Gateway and Keycloak OIDC remained/recovered via the public HTTPS path. Observed check RTO=${RTO_SECONDS}s."
echo 'Evidence boundary: this proves only this executed router-pod fault on this environment; it does not prove worker, zone, external LB, DNS, certificate or site HA.'
