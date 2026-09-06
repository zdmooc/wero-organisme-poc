#!/usr/bin/env bash
set -euo pipefail

PROJECT="wero-poc"
GITOPS_NS="openshift-gitops"
APP="wero-poc-crc"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHAOS_POLICY="v6-chaos-deny-keycloak"
KEYCLOAK_RESTARTED=false

cleanup() {
  set +e
  oc delete networkpolicy "$CHAOS_POLICY" -n "$PROJECT" --ignore-not-found >/dev/null 2>&1 || true
  if [[ "$KEYCLOAK_RESTARTED" == "true" ]]; then
    configure_demo_users >/dev/null 2>&1 || true
  fi
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

configure_demo_users() {
  local kc_admin_user kc_admin_password alice_password auditor_password keycloak_pod

  oc rollout status deployment/keycloak -n "$PROJECT" --timeout=240s >/dev/null
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

echo "==> 1. Preconditions and healthy V6 baseline"
SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}')"
HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}')"
[[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] || {
  echo "Argo CD must be Synced/Healthy before Keycloak chaos (sync=$SYNC health=$HEALTH)"
  exit 1
}
[[ "$(oc get deployment keycloak -n "$PROJECT" -o jsonpath='{.spec.replicas}')" == "1" ]] || {
  echo "Keycloak must remain a single-replica SPOF for this test"
  exit 1
}
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "==> 2. Acquire a fresh short-lived JWT and select committed business state"
refresh_demo_tokens
GATEWAY_HOST="$(oc get route api-gateway -n "$PROJECT" -o jsonpath='{.spec.host}')"
EXISTING_PAYMENT_ID="$(pg_scalar "select payment_id from payments where status='SETTLED' order by created_at desc limit 1;")"
[[ -n "$EXISTING_PAYMENT_ID" ]] || { echo "No SETTLED payment available for JWT continuity check"; exit 1; }

PRE_CODE="$(curl -sS -o /tmp/v6-keycloak-pre.json -w '%{http_code}' \
  "http://${GATEWAY_HOST}/api/payments/${EXISTING_PAYMENT_ID}" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H 'X-Correlation-Id: V6-KEYCLOAK-PRE')"
[[ "$PRE_CODE" == "200" ]] || { echo "Pre-chaos authenticated read failed HTTP $PRE_CODE"; exit 1; }

echo "==> 3. Isolate Keycloak and replace its pod so no pre-existing IAM connection survives"
OLD_KEYCLOAK_POD="$(oc get pod -n "$PROJECT" -l app=keycloak -o jsonpath='{.items[0].metadata.name}')"
cat <<'EOF' | oc apply -n "$PROJECT" -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: v6-chaos-deny-keycloak
  labels:
    chaos.mayabanque.io/scenario: keycloak-outage
spec:
  podSelector:
    matchLabels:
      app: keycloak
  policyTypes:
    - Ingress
  ingress: []
EOF
oc delete pod "$OLD_KEYCLOAK_POD" -n "$PROJECT" --wait=false >/dev/null
KEYCLOAK_RESTARTED=true
oc rollout status deployment/keycloak -n "$PROJECT" --timeout=240s >/dev/null
NEW_KEYCLOAK_POD="$(oc get pod -n "$PROJECT" -l app=keycloak -o jsonpath='{.items[0].metadata.name}')"
[[ "$NEW_KEYCLOAK_POD" != "$OLD_KEYCLOAK_POD" ]] || { echo "Keycloak pod was not replaced"; exit 1; }

# A restarted CRC Keycloak imports demo users without the external demo
# passwords. Restore them from Secrets through localhost while ingress remains
# denied, so the following token failure proves IAM network unavailability,
# not missing credentials.
configure_demo_users

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
  echo "Fresh Alice token unexpectedly succeeded while Keycloak ingress was denied"
  exit 1
}
echo "existing JWT accepted; fresh token acquisition unavailable as expected"

echo "==> 5. Restore Keycloak connectivity and measure fresh-token recovery"
RECOVERY_START="$(date +%s)"
oc delete networkpolicy "$CHAOS_POLICY" -n "$PROJECT" --ignore-not-found >/dev/null

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
  echo "Fresh token acquisition did not recover after Keycloak connectivity returned"
  exit 1
}
AUTH_RTO="$(( $(date +%s) - RECOVERY_START ))"
unset FRESH_TOKEN OUTAGE_TOKEN

echo "fresh token acquisition recovered in ${AUTH_RTO}s"

echo "==> 6. Full V5 business/observability regression after Keycloak recovery"
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "V6 OK (phase B3): an already-issued JWT remained usable during a deterministic Keycloak ingress outage, fresh token acquisition failed while IAM was unavailable, token issuance recovered in ${AUTH_RTO}s after connectivity returned, and the full V5 regression passed afterward. This validates CRC degraded-mode behavior with cached JWT verification; it does not make the single-instance Keycloak deployment HA."
