#!/usr/bin/env bash
set -euo pipefail

PROJECT="wero-poc"
GITOPS_NS="openshift-gitops"
APP="wero-poc-crc"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELF_HEAL_SUSPENDED=false

set_self_heal() {
  local value="$1"
  oc patch application "$APP" -n "$GITOPS_NS" --type=merge \
    -p "{\"spec\":{\"syncPolicy\":{\"automated\":{\"selfHeal\":${value}}}}}" >/dev/null
}

configure_demo_users() {
  local kc_admin_user kc_admin_password alice_password auditor_password keycloak_pod

  oc rollout status deployment/keycloak -n "$PROJECT" --timeout=420s >/dev/null
  keycloak_pod="$(oc get pods -n "$PROJECT" -l app=keycloak --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)"
  [[ -n "$keycloak_pod" ]] || return 1

  kc_admin_user="$(oc get secret keycloak-admin -n "$PROJECT" -o jsonpath='{.data.username}' | base64 -d)"
  kc_admin_password="$(oc get secret keycloak-admin -n "$PROJECT" -o jsonpath='{.data.password}' | base64 -d)"
  alice_password="$(oc get secret wero-v3-demo-users -n "$PROJECT" -o jsonpath='{.data.ALICE_PASSWORD}' | base64 -d)"
  auditor_password="$(oc get secret wero-v3-demo-users -n "$PROJECT" -o jsonpath='{.data.AUDITOR_PASSWORD}' | base64 -d)"

  MSYS_NO_PATHCONV=1 oc exec -n "$PROJECT" "$keycloak_pod" -- /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://127.0.0.1:8080 --realm master --user "$kc_admin_user" --password "$kc_admin_password" >/dev/null
  MSYS_NO_PATHCONV=1 oc exec -n "$PROJECT" "$keycloak_pod" -- /opt/keycloak/bin/kcadm.sh set-password \
    -r mayabanque --username alice --new-password "$alice_password" >/dev/null
  MSYS_NO_PATHCONV=1 oc exec -n "$PROJECT" "$keycloak_pod" -- /opt/keycloak/bin/kcadm.sh set-password \
    -r mayabanque --username auditor --new-password "$auditor_password" >/dev/null

  unset kc_admin_password alice_password auditor_password
}

cleanup() {
  set +e
  oc scale deployment/keycloak -n "$PROJECT" --replicas=1 >/dev/null 2>&1 || true
  if [[ "$SELF_HEAL_SUSPENDED" == "true" ]]; then
    set_self_heal true >/dev/null 2>&1 || true
  fi
  oc rollout status deployment/keycloak -n "$PROJECT" --timeout=420s >/dev/null 2>&1 || true
  configure_demo_users >/dev/null 2>&1 || true
  unset ALICE_TOKEN AUDITOR_TOKEN SCA_CODE
}
trap cleanup EXIT

pg_scalar() {
  local sql="$1"
  oc exec -n "$PROJECT" deployment/postgresql -- sh -lc \
    "psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -Atc \"$sql\"" \
    2>/dev/null | tr -d '\r'
}

issue_alice_token() {
  local kc_host alice_password response token
  kc_host="$(oc get route keycloak -n "$PROJECT" -o jsonpath='{.spec.host}')"
  alice_password="$(oc get secret wero-v3-demo-users -n "$PROJECT" \
    -o jsonpath='{.data.ALICE_PASSWORD}' | base64 -d)"
  response="$(curl -sS --connect-timeout 2 --max-time 4 -X POST \
    "http://${kc_host}/realms/mayabanque/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'client_id=mayabanque-cli' \
    -d 'grant_type=password' \
    -d 'username=alice' \
    --data-urlencode "password=${alice_password}" 2>/dev/null || true)"
  token="$(printf '%s' "$response" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  unset alice_password response
  printf '%s' "$token"
}

refresh_demo_tokens() {
  local kc_host alice_password auditor_password

  kc_host="$(oc get route keycloak -n "$PROJECT" -o jsonpath='{.spec.host}')"
  alice_password="$(oc get secret wero-v3-demo-users -n "$PROJECT" \
    -o jsonpath='{.data.ALICE_PASSWORD}' | base64 -d)"
  auditor_password="$(oc get secret wero-v3-demo-users -n "$PROJECT" \
    -o jsonpath='{.data.AUDITOR_PASSWORD}' | base64 -d)"
  export SCA_CODE="$(oc get secret wero-v3-app -n "$PROJECT" \
    -o jsonpath='{.data.SCA_DEMO_CODE}' | base64 -d)"

  export ALICE_TOKEN="$(curl -sS -X POST \
    "http://${kc_host}/realms/mayabanque/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'client_id=mayabanque-cli' \
    -d 'grant_type=password' \
    -d 'username=alice' \
    --data-urlencode "password=${alice_password}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"

  export AUDITOR_TOKEN="$(curl -sS -X POST \
    "http://${kc_host}/realms/mayabanque/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'client_id=mayabanque-cli' \
    -d 'grant_type=password' \
    -d 'username=auditor' \
    --data-urlencode "password=${auditor_password}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"

  unset alice_password auditor_password
  [[ -n "$ALICE_TOKEN" ]] || { echo "Failed to obtain fresh Alice JWT"; exit 1; }
  [[ -n "$AUDITOR_TOKEN" ]] || { echo "Failed to obtain fresh Auditor JWT"; exit 1; }
  [[ -n "$SCA_CODE" ]] || { echo "SCA demo code is unavailable"; exit 1; }
  echo "fresh demo JWTs acquired (values not printed)"
}

echo "==> 1. Recover any stale Keycloak chaos and wait for a healthy V6 baseline"
set_self_heal true
oc scale deployment/keycloak -n "$PROJECT" --replicas=1 >/dev/null
oc rollout status deployment/keycloak -n "$PROJECT" --timeout=420s >/dev/null

BASELINE_READY=false
for _ in $(seq 1 60); do
  SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    BASELINE_READY=true
    break
  fi
  sleep 5
done
[[ "$BASELINE_READY" == "true" ]] || {
  echo "Argo CD did not return to Synced/Healthy before Keycloak chaos (sync=${SYNC:-<none>} health=${HEALTH:-<none>})"
  exit 1
}
echo "sync=Synced health=Healthy"

[[ "$(oc get deployment keycloak -n "$PROJECT" -o jsonpath='{.spec.replicas}')" == "1" ]] || {
  echo "Keycloak must remain a single-replica SPOF for this test"
  exit 1
}
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "==> 2. Acquire a fresh short-lived JWT and warm OIDC/JWK caches"
refresh_demo_tokens
GATEWAY_HOST="$(oc get route api-gateway -n "$PROJECT" -o jsonpath='{.spec.host}')"
EXISTING_PAYMENT_ID="$(pg_scalar "select payment_id from payments where status='SETTLED' order by created_at desc limit 1;")"
[[ -n "$EXISTING_PAYMENT_ID" ]] || { echo "No SETTLED payment available for JWT continuity check"; exit 1; }

PRE_CODE="$(curl -sS -o /tmp/v6-keycloak-pre.json -w '%{http_code}' \
  "http://${GATEWAY_HOST}/api/payments/${EXISTING_PAYMENT_ID}" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H 'X-Correlation-Id: V6-KEYCLOAK-PRE')"
[[ "$PRE_CODE" == "200" ]] || { echo "Pre-chaos authenticated read failed HTTP $PRE_CODE"; exit 1; }

echo "==> 3. Stop the single Keycloak replica while temporarily suspending Argo self-heal"
# On single-node CRC the OpenShift router may use node/host networking, so a
# pod-ingress NetworkPolicy is not a reliable way to make the external Route
# unavailable. Suspend self-heal only for this controlled chaos window and
# scale the single Keycloak replica to zero to create a deterministic IAM outage.
set_self_heal false
SELF_HEAL_SUSPENDED=true
oc scale deployment/keycloak -n "$PROJECT" --replicas=0 >/dev/null

STOPPED=false
for _ in $(seq 1 30); do
  READY="$(oc get deployment keycloak -n "$PROJECT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  PODS="$(oc get pods -n "$PROJECT" -l app=keycloak --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${READY:-0}" == "0" && "$PODS" == "0" ]]; then
    STOPPED=true
    break
  fi
  sleep 2
done
[[ "$STOPPED" == "true" ]] || { echo "Keycloak did not stop deterministically"; exit 1; }

echo "==> 4. Existing JWT remains usable while fresh token acquisition is unavailable"
EXISTING_CODE="$(curl -sS --connect-timeout 2 --max-time 8 -o /tmp/v6-keycloak-existing.json -w '%{http_code}' \
  "http://${GATEWAY_HOST}/api/payments/${EXISTING_PAYMENT_ID}" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H 'X-Correlation-Id: V6-KEYCLOAK-EXISTING' 2>/dev/null || true)"
[[ "$EXISTING_CODE" == "200" ]] || {
  echo "Existing JWT was not accepted during Keycloak outage (HTTP ${EXISTING_CODE:-<none>})"
  exit 1
}
grep -q '"status":"SETTLED"' /tmp/v6-keycloak-existing.json || {
  echo "Existing JWT request did not return the expected committed payment"
  exit 1
}

OUTAGE_TOKEN="$(issue_alice_token)"
[[ -z "$OUTAGE_TOKEN" ]] || {
  echo "Fresh Alice token unexpectedly succeeded while Keycloak had zero replicas"
  exit 1
}
echo "existing JWT accepted; fresh token acquisition unavailable as expected"

echo "==> 5. Restore Keycloak and measure token + JWK authorization recovery"
RECOVERY_START="$(date +%s)"
oc scale deployment/keycloak -n "$PROJECT" --replicas=1 >/dev/null
oc rollout status deployment/keycloak -n "$PROJECT" --timeout=420s >/dev/null
configure_demo_users

TOKEN_RECOVERED=false
FRESH_TOKEN=""
for _ in $(seq 1 60); do
  FRESH_TOKEN="$(issue_alice_token)"
  if [[ -n "$FRESH_TOKEN" ]]; then
    TOKEN_RECOVERED=true
    break
  fi
  sleep 2
done
[[ "$TOKEN_RECOVERED" == "true" ]] || {
  echo "Fresh token acquisition did not recover after Keycloak returned"
  exit 1
}
TOKEN_RTO="$(( $(date +%s) - RECOVERY_START ))"
unset FRESH_TOKEN OUTAGE_TOKEN

echo "fresh token acquisition recovered in ${TOKEN_RTO}s; waiting for resource-server JWK convergence"

# The CRC Keycloak dev store can generate a new signing key after restart. A
# resource server that cached the previous JWK set can transiently reject a
# freshly issued token with an unknown kid until its OIDC provider refreshes.
# Prove end-to-end authorization recovery explicitly before the full V5 run.
refresh_demo_tokens
JWK_READY=false
PAYMENT_CODE=""
AUDIT_CODE=""
for _ in $(seq 1 90); do
  PAYMENT_CODE="$(curl -sS --connect-timeout 2 --max-time 8 \
    -o /tmp/v6-keycloak-jwk-payment.json -w '%{http_code}' \
    "http://${GATEWAY_HOST}/api/payments/${EXISTING_PAYMENT_ID}" \
    -H "Authorization: Bearer ${ALICE_TOKEN}" \
    -H 'X-Correlation-Id: V6-KEYCLOAK-JWK-PAYMENT' 2>/dev/null || true)"

  AUDIT_CODE="$(curl -sS --connect-timeout 2 --max-time 8 \
    -o /tmp/v6-keycloak-jwk-audit.json -w '%{http_code}' \
    "http://${GATEWAY_HOST}/api/audit/events/${EXISTING_PAYMENT_ID}" \
    -H "Authorization: Bearer ${AUDITOR_TOKEN}" \
    -H 'X-Correlation-Id: V6-KEYCLOAK-JWK-AUDIT' 2>/dev/null || true)"

  if [[ "$PAYMENT_CODE" == "200" && "$AUDIT_CODE" == "200" ]] \
     && grep -q '"status":"SETTLED"' /tmp/v6-keycloak-jwk-payment.json \
     && grep -q 'PAYMENT_SETTLED' /tmp/v6-keycloak-jwk-audit.json; then
    JWK_READY=true
    break
  fi
  sleep 2
done
[[ "$JWK_READY" == "true" ]] || {
  echo "Fresh JWT authorization did not converge after Keycloak restart (paymentHTTP=${PAYMENT_CODE:-<none>} auditHTTP=${AUDIT_CODE:-<none>})"
  exit 1
}
AUTHZ_RTO="$(( $(date +%s) - RECOVERY_START ))"
echo "fresh JWT business authorization recovered in ${AUTHZ_RTO}s"

set_self_heal true
SELF_HEAL_SUSPENDED=false
oc annotate application "$APP" -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null

ARGO_READY=false
for _ in $(seq 1 60); do
  SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    ARGO_READY=true
    break
  fi
  sleep 5
done
[[ "$ARGO_READY" == "true" ]] || { echo "Argo CD did not return to Synced/Healthy after Keycloak recovery"; exit 1; }

echo "==> 6. Full V5 business/observability regression after Keycloak recovery"
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "V6 OK (phase B3): an already-issued JWT remained usable while the single Keycloak replica was stopped, fresh token acquisition failed during the IAM outage, token issuance recovered in ${TOKEN_RTO}s and fresh-JWT business authorization/JWK convergence recovered in ${AUTHZ_RTO}s after Keycloak restarted, Argo CD returned to Synced/Healthy, and the full V5 regression passed afterward. This validates a time-bounded CRC degraded mode with cached JWT verification; it does not make the single-instance Keycloak deployment HA."
