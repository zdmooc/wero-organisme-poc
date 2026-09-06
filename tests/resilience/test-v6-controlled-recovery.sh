#!/usr/bin/env bash
set -euo pipefail

: "${ALICE_TOKEN:?Set ALICE_TOKEN before running B6}"
: "${SCA_CODE:?Set SCA_CODE before running B6}"

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
}
trap cleanup EXIT

pg_scalar() {
  local sql="$1"
  oc exec -n "$PROJECT" deployment/postgresql -- sh -lc \
    "psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -Atc \"$sql\"" \
    2>/dev/null | tr -d '\r'
}

echo "==> 1. Preconditions"
SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}')"
HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}')"
[[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] || { echo "Argo must be Synced/Healthy"; exit 1; }
[[ "$(oc get deployment mock-wero -n "$PROJECT" -o jsonpath='{.spec.replicas}')" == "2" ]] || exit 1
oc rollout status deployment/mock-wero -n "$PROJECT" --timeout=240s >/dev/null

GATEWAY_HOST="$(oc get route api-gateway -n "$PROJECT" -o jsonpath='{.spec.host}')"
STAMP="$(date +%s)"
CORR_ID="V6-CONTROLLED-RECOVERY-${STAMP}"
PAYMENT_ID="PAY-V6-RECOVER-${STAMP}"
IDEM_KEY="idem-v6-recover-${STAMP}"
PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":9450,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\"}"
CONSENT_PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":9450,\"currency\":\"EUR\",\"creditorAlias\":\"+33630000002\"}"

echo "==> 2. Create and authorize payment"
CONSENT_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/consents" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}" \
  -H 'Content-Type: application/json' -d "$CONSENT_PAYLOAD")"
CONSENT_ID="$(echo "$CONSENT_JSON" | sed -n 's/.*"consentId":"\([^"]*\)".*/\1/p')"
[[ -n "$CONSENT_ID" ]] || { echo "$CONSENT_JSON"; exit 1; }
echo "$CONSENT_JSON" | grep -q '"status":"PENDING_SCA"'

SCA_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/consents/${CONSENT_ID}/sca" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}" \
  -H 'Content-Type: application/json' -d "{\"code\":\"${SCA_CODE}\"}")"
echo "$SCA_JSON" | grep -q '"status":"AUTHORIZED"' || { echo "$SCA_JSON"; exit 1; }

echo "==> 3. Stop Wero/EPI and create pre-rail UNKNOWN"
set_self_heal false
SELF_HEAL_SUSPENDED=true
oc scale deployment/mock-wero -n "$PROJECT" --replicas=0 >/dev/null
for _ in $(seq 1 30); do
  PODS="$(oc get pods -n "$PROJECT" -l app=mock-wero --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$PODS" == "0" ]] && break
  sleep 2
done
[[ "$(oc get pods -n "$PROJECT" -l app=mock-wero --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] || exit 1

CREATE_CODE="$(curl -sS --connect-timeout 2 --max-time 12 -o /tmp/v6-b6-create.json -w '%{http_code}' \
  -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "Idempotency-Key: ${IDEM_KEY}" \
  -H "X-Consent-Id: ${CONSENT_ID}" -H "X-Correlation-Id: ${CORR_ID}" \
  -H 'Content-Type: application/json' -d "$PAYLOAD" 2>/dev/null || true)"
CREATE_JSON="$(cat /tmp/v6-b6-create.json 2>/dev/null || true)"
echo "$CREATE_JSON"
[[ "$CREATE_CODE" == "202" ]] || exit 1
echo "$CREATE_JSON" | grep -q '"status":"UNKNOWN"' || exit 1
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${PAYMENT_ID}';")" == "0" ]] || exit 1
[[ "$(pg_scalar "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}' and entry_type='SETTLEMENT';")" == "0" ]] || exit 1

echo "==> 4. Restore Wero/EPI and reconcile first"
RECOVERY_START="$(date +%s)"
oc scale deployment/mock-wero -n "$PROJECT" --replicas=2 >/dev/null
oc rollout status deployment/mock-wero -n "$PROJECT" --timeout=240s >/dev/null
set_self_heal true
SELF_HEAL_SUSPENDED=false
oc annotate application "$APP" -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
for _ in $(seq 1 60); do
  SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] && break
  sleep 5
done
[[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] || exit 1
WERO_RTO="$(( $(date +%s) - RECOVERY_START ))"

RECON_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/reconcile" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}-RECON")"
echo "$RECON_JSON"
echo "$RECON_JSON" | grep -q '"railStatus":"NOT_FOUND"' || exit 1
echo "$RECON_JSON" | grep -q '"afterStatus":"UNKNOWN"' || exit 1

echo "==> 5. Invalid recovery confirmation cannot reach rail"
BAD_CODE="$(curl -sS -o /tmp/v6-b6-bad.json -w '%{http_code}' \
  -X POST "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/recover" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}-BAD" \
  -H 'Content-Type: application/json' -d '{"confirmation":"NO"}')"
[[ "$BAD_CODE" == "400" ]] || { echo "Expected 400, got $BAD_CODE"; exit 1; }
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${PAYMENT_ID}';")" == "0" ]] || exit 1

echo "==> 6. Explicit controlled recovery"
RECOVER_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/recover" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}-RECOVER" \
  -H 'Content-Type: application/json' \
  -d '{"confirmation":"RESUBMIT_AFTER_RAIL_NOT_FOUND"}')"
echo "$RECOVER_JSON"
echo "$RECOVER_JSON" | grep -q '"railStatusBefore":"NOT_FOUND"' || exit 1
echo "$RECOVER_JSON" | grep -q '"action":"RESUBMITTED"' || exit 1
echo "$RECOVER_JSON" | grep -q '"afterStatus":"SETTLED"' || exit 1
SETTLEMENT_ID="$(echo "$RECOVER_JSON" | sed -n 's/.*"settlementId":"\([^"]*\)".*/\1/p')"
[[ -n "$SETTLEMENT_ID" ]] || exit 1

[[ "$(pg_scalar "select status from payments where payment_id='${PAYMENT_ID}';")" == "SETTLED" ]] || exit 1
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${PAYMENT_ID}';")" == "1" ]] || exit 1
[[ "$(pg_scalar "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}' and entry_type='SETTLEMENT';")" == "1" ]] || exit 1
[[ "$(pg_scalar "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}' and event_type='PAYMENT_RECOVERY_STARTED';")" == "1" ]] || exit 1
[[ "$(pg_scalar "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}' and event_type='PAYMENT_RECOVERED';")" == "1" ]] || exit 1

echo "==> 7. Repeated recovery is a no-op"
SECOND_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/recover" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}-AGAIN" \
  -H 'Content-Type: application/json' \
  -d '{"confirmation":"RESUBMIT_AFTER_RAIL_NOT_FOUND"}')"
echo "$SECOND_JSON"
echo "$SECOND_JSON" | grep -q '"action":"ALREADY_FINAL"' || exit 1
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${PAYMENT_ID}';")" == "1" ]] || exit 1
[[ "$(pg_scalar "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}' and entry_type='SETTLEMENT';")" == "1" ]] || exit 1

echo "V6 OK (phase B6): pre-rail UNKNOWN was preserved until an explicit recovery confirmation; a fresh rail NOT_FOUND preflight preceded a single claimed resubmission, the payment reached SETTLED with one rail row and one settlement ledger, repeated recovery was a no-op, and Wero/EPI recovered in ${WERO_RTO}s. This is controlled recovery for the lab, not automatic retry of arbitrary UNKNOWN payments."
