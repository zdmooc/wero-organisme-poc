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

cleanup() {
  set +e
  oc scale deployment/mock-wero -n "$PROJECT" --replicas=2 >/dev/null 2>&1 || true
  if [[ "$SELF_HEAL_SUSPENDED" == "true" ]]; then
    set_self_heal true >/dev/null 2>&1 || true
  fi
  oc rollout status deployment/mock-wero -n "$PROJECT" --timeout=240s >/dev/null 2>&1 || true
  oc annotate application "$APP" -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  unset ALICE_TOKEN AUDITOR_TOKEN SCA_CODE
}
trap cleanup EXIT

pg_scalar() {
  local sql="$1"
  oc exec -n "$PROJECT" deployment/postgresql -- sh -lc \
    "psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -Atc \"$sql\"" \
    2>/dev/null | tr -d '\r'
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

echo "==> 1. Preconditions and healthy V6 baseline"
SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}')"
HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}')"
[[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] || {
  echo "Argo CD must be Synced/Healthy before Wero outage (sync=$SYNC health=$HEALTH)"
  exit 1
}
[[ "$(oc get deployment mock-wero -n "$PROJECT" -o jsonpath='{.spec.replicas}')" == "2" ]] || {
  echo "mock-wero must have two replicas before B5"
  exit 1
}
oc rollout status deployment/mock-wero -n "$PROJECT" --timeout=240s >/dev/null
[[ "$(oc get pdb mock-wero -n "$PROJECT" -o jsonpath='{.spec.minAvailable}')" == "1" ]] || {
  echo "mock-wero PDB minAvailable must be 1"
  exit 1
}
[[ "$(pg_scalar "select to_regclass('public.sct_inst_transfers');")" == "sct_inst_transfers" ]] || {
  echo "B4 shared SCT Inst state must exist before B5"
  exit 1
}
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "==> 2. Create and authorize a payment before the Wero outage"
refresh_demo_tokens
GATEWAY_HOST="$(oc get route api-gateway -n "$PROJECT" -o jsonpath='{.spec.host}')"
STAMP="$(date +%s)"
CORR_ID="V6-WERO-OUTAGE-${STAMP}"
PAYMENT_ID="PAY-V6-WERO-OUTAGE-${STAMP}"
IDEM_KEY="idem-v6-wero-outage-${STAMP}"
PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":8350,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\"}"
CONSENT_PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":8350,\"currency\":\"EUR\",\"creditorAlias\":\"+33630000002\"}"

CONSENT_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/consents" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "X-Correlation-Id: ${CORR_ID}" \
  -H 'Content-Type: application/json' \
  -d "$CONSENT_PAYLOAD")"
CONSENT_ID="$(echo "$CONSENT_JSON" | sed -n 's/.*"consentId":"\([^"]*\)".*/\1/p')"
[[ -n "$CONSENT_ID" ]] || { echo "consentId missing: $CONSENT_JSON"; exit 1; }
echo "$CONSENT_JSON" | grep -q '"status":"PENDING_SCA"'

SCA_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/consents/${CONSENT_ID}/sca" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "X-Correlation-Id: ${CORR_ID}" \
  -H 'Content-Type: application/json' \
  -d "{\"code\":\"${SCA_CODE}\"}")"
echo "$SCA_JSON" | grep -q '"status":"AUTHORIZED"' || { echo "$SCA_JSON"; exit 1; }

echo "==> 3. Stop both Wero/EPI mock replicas while temporarily suspending Argo self-heal"
set_self_heal false
SELF_HEAL_SUSPENDED=true
oc scale deployment/mock-wero -n "$PROJECT" --replicas=0 >/dev/null

STOPPED=false
for _ in $(seq 1 30); do
  READY="$(oc get deployment mock-wero -n "$PROJECT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  PODS="$(oc get pods -n "$PROJECT" -l app=mock-wero --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${READY:-0}" == "0" && "$PODS" == "0" ]]; then
    STOPPED=true
    break
  fi
  sleep 2
done
[[ "$STOPPED" == "true" ]] || { echo "mock-wero did not stop deterministically"; exit 1; }

echo "==> 4. Submit the payment while Wero/EPI is unavailable"
HTTP_CODE="$(curl -sS --connect-timeout 2 --max-time 12 \
  -o /tmp/v6-wero-outage-payment.json -w '%{http_code}' \
  -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Idempotency-Key: ${IDEM_KEY}" \
  -H "X-Consent-Id: ${CONSENT_ID}" \
  -H "X-Correlation-Id: ${CORR_ID}" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" 2>/dev/null || true)"
PAYMENT_JSON="$(cat /tmp/v6-wero-outage-payment.json 2>/dev/null || true)"
echo "$PAYMENT_JSON"
[[ "$HTTP_CODE" == "202" ]] || { echo "Expected HTTP 202 UNKNOWN, got ${HTTP_CODE:-<none>}"; exit 1; }
echo "$PAYMENT_JSON" | grep -q '"status":"UNKNOWN"' || { echo "Expected UNKNOWN during Wero outage"; exit 1; }

LOCAL_STATUS="$(pg_scalar "select status from payments where payment_id='${PAYMENT_ID}';")"
LEDGER_COUNT="$(pg_scalar "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}' and entry_type='SETTLEMENT';")"
RAIL_COUNT="$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${PAYMENT_ID}';")"
OUTBOX_TYPES="$(pg_scalar "select string_agg(event_type, ',' order by id) from outbox_events where aggregate_id='${PAYMENT_ID}';")"
[[ "$LOCAL_STATUS" == "UNKNOWN" ]] || { echo "Local status=$LOCAL_STATUS, expected UNKNOWN"; exit 1; }
[[ "$LEDGER_COUNT" == "0" ]] || { echo "Settlement ledger unexpectedly exists during pre-rail Wero outage"; exit 1; }
[[ "$RAIL_COUNT" == "0" ]] || { echo "SCT Inst unexpectedly received the payment while Wero was stopped"; exit 1; }
[[ "$OUTBOX_TYPES" == *"PAYMENT_UNKNOWN"* ]] || { echo "PAYMENT_UNKNOWN outbox event missing: $OUTBOX_TYPES"; exit 1; }
echo "Wero outage evidence: local=UNKNOWN railRows=0 settlementLedger=0 outbox=$OUTBOX_TYPES"

echo "==> 5. Replay the same idempotency key during the outage: no blind remote retry"
REPLAY_HTTP="$(curl -sS --connect-timeout 2 --max-time 8 \
  -o /tmp/v6-wero-outage-replay.json -w '%{http_code}' \
  -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Idempotency-Key: ${IDEM_KEY}" \
  -H "X-Consent-Id: ${CONSENT_ID}" \
  -H "X-Correlation-Id: ${CORR_ID}-REPLAY" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" 2>/dev/null || true)"
REPLAY_JSON="$(cat /tmp/v6-wero-outage-replay.json 2>/dev/null || true)"
[[ "$REPLAY_HTTP" == "200" ]] || { echo "Idempotent replay expected HTTP 200, got $REPLAY_HTTP"; exit 1; }
echo "$REPLAY_JSON" | grep -q '"status":"UNKNOWN"' || { echo "$REPLAY_JSON"; exit 1; }
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${PAYMENT_ID}';")" == "0" ]] || {
  echo "Blind replay reached SCT Inst during Wero outage"
  exit 1
}
[[ "$(pg_scalar "select count(*) from payments where payment_id='${PAYMENT_ID}';")" == "1" ]] || {
  echo "Idempotent replay duplicated the payment row"
  exit 1
}

echo "==> 6. Restore Wero/EPI and return Argo CD to desired state"
RECOVERY_START="$(date +%s)"
oc scale deployment/mock-wero -n "$PROJECT" --replicas=2 >/dev/null
oc rollout status deployment/mock-wero -n "$PROJECT" --timeout=240s >/dev/null
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
[[ "$ARGO_READY" == "true" ]] || { echo "Argo CD did not return to Synced/Healthy after Wero recovery"; exit 1; }
RECOVERY_SECONDS="$(( $(date +%s) - RECOVERY_START ))"
echo "mock-wero recovered to two replicas and Argo Synced/Healthy in ${RECOVERY_SECONDS}s"

echo "==> 7. Same idempotency key after recovery still does not blindly replay"
POST_RECOVERY_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Idempotency-Key: ${IDEM_KEY}" \
  -H "X-Consent-Id: ${CONSENT_ID}" \
  -H "X-Correlation-Id: ${CORR_ID}-AFTER" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD")"
echo "$POST_RECOVERY_JSON" | grep -q '"status":"UNKNOWN"' || { echo "$POST_RECOVERY_JSON"; exit 1; }
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${PAYMENT_ID}';")" == "0" ]] || {
  echo "Post-recovery idempotent replay unexpectedly created a rail settlement"
  exit 1
}

echo "==> 8. Reconciliation sees no rail settlement and preserves UNKNOWN"
RECON_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/reconcile" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "X-Correlation-Id: ${CORR_ID}-RECON")"
echo "$RECON_JSON"
echo "$RECON_JSON" | grep -q '"beforeStatus":"UNKNOWN"' || exit 1
echo "$RECON_JSON" | grep -q '"railStatus":"NOT_FOUND"' || exit 1
echo "$RECON_JSON" | grep -q '"afterStatus":"UNKNOWN"' || exit 1
[[ "$(pg_scalar "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}' and entry_type='SETTLEMENT';")" == "0" ]] || {
  echo "Reconciliation created a settlement ledger without rail evidence"
  exit 1
}

echo "==> 9. Full V5 business/observability regression after Wero recovery"
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "V6 OK (phase B5): stopping both Wero/EPI mock replicas caused the authorized payment to enter UNKNOWN before reaching SCT Inst; the shared rail contained 0 rows and the settlement ledger 0 rows, replaying the same idempotency key during and after the outage did not blindly resend the payment, reconciliation returned rail NOT_FOUND and preserved UNKNOWN, Wero recovered to two replicas in ${RECOVERY_SECONDS}s, Argo CD returned to Synced/Healthy, and the full V5 regression passed. This validates safe degraded-state/idempotency behavior; it intentionally exposes that a pre-rail UNKNOWN still needs an explicit controlled recovery policy rather than an automatic blind retry."
