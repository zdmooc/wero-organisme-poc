#!/usr/bin/env bash
set -euo pipefail

PROJECT="wero-poc"
GITOPS_NS="openshift-gitops"
APP="wero-poc-crc"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

cleanup() {
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

pod_from_prefixed_log() {
  sed -n 's#^\[pod/\([^/]*\)/[^]]*\].*$#\1#p'
}

echo "==> 1. Preconditions: V6 healthy and mock-sct-inst N+1 shared-state target"
SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}')"
HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}')"
[[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] || {
  echo "Argo CD must be Synced/Healthy before SCT Inst failover (sync=$SYNC health=$HEALTH)"
  exit 1
}
[[ "$(oc get deployment mock-sct-inst -n "$PROJECT" -o jsonpath='{.spec.replicas}')" == "2" ]] || {
  echo "mock-sct-inst must be configured with 2 replicas for B4"
  exit 1
}
oc rollout status deployment/mock-sct-inst -n "$PROJECT" --timeout=240s >/dev/null
READY="$(oc get deployment mock-sct-inst -n "$PROJECT" -o jsonpath='{.status.readyReplicas}')"
[[ "${READY:-0}" -ge 2 ]] || { echo "mock-sct-inst readyReplicas=${READY:-0}, expected 2"; exit 1; }
[[ "$(oc get pdb mock-sct-inst -n "$PROJECT" -o jsonpath='{.spec.minAvailable}')" == "1" ]] || {
  echo "mock-sct-inst PDB minAvailable must be 1"
  exit 1
}

EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "==> 2. Create UNKNOWN locally after the rail commits SETTLED"
refresh_demo_tokens
GATEWAY_HOST="$(oc get route api-gateway -n "$PROJECT" -o jsonpath='{.spec.host}')"
STAMP="$(date +%s)"
CORR_ID="V6-SCT-HA-${STAMP}"
PAYMENT_ID="PAY-V6-SCT-HA-${STAMP}"
IDEM_KEY="idem-v6-sct-ha-${STAMP}"
PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":7250,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\",\"simulateMode\":\"TIMEOUT_AFTER_SETTLEMENT\"}"
CONSENT_PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":7250,\"currency\":\"EUR\",\"creditorAlias\":\"+33630000002\"}"

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

PAYMENT_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Idempotency-Key: ${IDEM_KEY}" \
  -H "X-Consent-Id: ${CONSENT_ID}" \
  -H "X-Correlation-Id: ${CORR_ID}" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD")"
echo "$PAYMENT_JSON"
echo "$PAYMENT_JSON" | grep -q '"status":"UNKNOWN"' || {
  echo "Expected local UNKNOWN after TIMEOUT_AFTER_SETTLEMENT"
  exit 1
}

LOCAL_STATUS="$(pg_scalar "select status from payments where payment_id='${PAYMENT_ID}';")"
RAIL_ROW="$(pg_scalar "select status || '|' || settlement_id from sct_inst_transfers where payment_id='${PAYMENT_ID}';")"
RAIL_STATUS="${RAIL_ROW%%|*}"
RAIL_SETTLEMENT="${RAIL_ROW#*|}"
[[ "$LOCAL_STATUS" == "UNKNOWN" ]] || { echo "Local payment status=$LOCAL_STATUS, expected UNKNOWN"; exit 1; }
[[ "$RAIL_STATUS" == "SETTLED" && -n "$RAIL_SETTLEMENT" && "$RAIL_SETTLEMENT" != "$RAIL_ROW" ]] || {
  echo "Shared rail store does not contain a SETTLED row for $PAYMENT_ID: ${RAIL_ROW:-<none>}"
  exit 1
}
echo "local payment=UNKNOWN while shared SCT Inst state=SETTLED settlementId=$RAIL_SETTLEMENT"

echo "==> 3. Identify the pod that accepted the original SCT Inst POST"
HANDLER_LINE=""
for _ in $(seq 1 30); do
  HANDLER_LINE="$(oc logs -n "$PROJECT" -l app=mock-sct-inst --since=5m --prefix=true 2>/dev/null \
    | grep "paymentId=${PAYMENT_ID} sct-inst mode=TIMEOUT_AFTER_SETTLEMENT" \
    | tail -1 || true)"
  [[ -n "$HANDLER_LINE" ]] && break
  sleep 1
done
[[ -n "$HANDLER_LINE" ]] || { echo "Could not identify the SCT Inst pod that handled $PAYMENT_ID"; exit 1; }
HANDLER_POD="$(printf '%s\n' "$HANDLER_LINE" | pod_from_prefixed_log)"
[[ -n "$HANDLER_POD" ]] || { echo "Could not parse handler pod from: $HANDLER_LINE"; exit 1; }
echo "initial SCT Inst POST handled by pod/$HANDLER_POD"

echo "==> 4. Delete that exact pod while preserving one ready replica"
oc delete pod "$HANDLER_POD" -n "$PROJECT" --wait=true >/dev/null
SURVIVOR_READY=false
for _ in $(seq 1 30); do
  READY="$(oc get deployment mock-sct-inst -n "$PROJECT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  OLD_EXISTS="$(oc get pod "$HANDLER_POD" -n "$PROJECT" --ignore-not-found -o name 2>/dev/null || true)"
  if [[ -z "$OLD_EXISTS" && "${READY:-0}" -ge 1 ]]; then
    SURVIVOR_READY=true
    break
  fi
  sleep 1
done
[[ "$SURVIVOR_READY" == "true" ]] || {
  echo "mock-sct-inst lost all ready replicas after deleting $HANDLER_POD"
  oc get pods -n "$PROJECT" -l app=mock-sct-inst -o wide
  exit 1
}

echo "==> 5. Reconcile through another SCT Inst pod using the shared state"
RECON_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/reconcile" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "X-Correlation-Id: ${CORR_ID}-RECON")"
echo "$RECON_JSON"
echo "$RECON_JSON" | grep -q '"beforeStatus":"UNKNOWN"' || exit 1
echo "$RECON_JSON" | grep -q '"railStatus":"SETTLED"' || exit 1
echo "$RECON_JSON" | grep -q '"afterStatus":"SETTLED"' || exit 1
RECON_SETTLEMENT="$(echo "$RECON_JSON" | sed -n 's/.*"settlementId":"\([^"]*\)".*/\1/p')"
[[ "$RECON_SETTLEMENT" == "$RAIL_SETTLEMENT" ]] || {
  echo "Reconciliation settlementId=$RECON_SETTLEMENT differs from shared rail settlementId=$RAIL_SETTLEMENT"
  exit 1
}

STATUS_LINE=""
for _ in $(seq 1 30); do
  STATUS_LINE="$(oc logs -n "$PROJECT" -l app=mock-sct-inst --since=3m --prefix=true 2>/dev/null \
    | grep "paymentId=${PAYMENT_ID} sct-inst status lookup" \
    | tail -1 || true)"
  [[ -n "$STATUS_LINE" ]] && break
  sleep 1
done
[[ -n "$STATUS_LINE" ]] || { echo "Could not identify the SCT Inst pod that answered reconciliation"; exit 1; }
STATUS_POD="$(printf '%s\n' "$STATUS_LINE" | pod_from_prefixed_log)"
[[ -n "$STATUS_POD" ]] || { echo "Could not parse status pod from: $STATUS_LINE"; exit 1; }
[[ "$STATUS_POD" != "$HANDLER_POD" ]] || {
  echo "Status lookup unexpectedly used the deleted original pod $HANDLER_POD"
  exit 1
}
echo "status/reconciliation served by different pod/$STATUS_POD"

echo "==> 6. Verify shared rail row and business idempotence"
RAIL_COUNT="$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${PAYMENT_ID}';")"
FINAL_STATUS="$(pg_scalar "select status from payments where payment_id='${PAYMENT_ID}';")"
FINAL_SETTLEMENT="$(pg_scalar "select settlement_id from payments where payment_id='${PAYMENT_ID}';")"
LEDGER_COUNT="$(pg_scalar "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}' and entry_type='SETTLEMENT';")"
[[ "$RAIL_COUNT" == "1" ]] || { echo "Expected one shared rail row, got $RAIL_COUNT"; exit 1; }
[[ "$FINAL_STATUS" == "SETTLED" ]] || { echo "Final local status=$FINAL_STATUS"; exit 1; }
[[ "$FINAL_SETTLEMENT" == "$RAIL_SETTLEMENT" ]] || { echo "Local settlementId diverged from rail"; exit 1; }
[[ "$LEDGER_COUNT" == "1" ]] || { echo "Settlement ledger count=$LEDGER_COUNT, expected 1"; exit 1; }

RECON_AGAIN="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/reconcile" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "X-Correlation-Id: ${CORR_ID}-RECON-2")"
echo "$RECON_AGAIN" | grep -q '"beforeStatus":"SETTLED"' || { echo "$RECON_AGAIN"; exit 1; }
echo "$RECON_AGAIN" | grep -q '"afterStatus":"SETTLED"' || { echo "$RECON_AGAIN"; exit 1; }
LEDGER_AFTER_RETRY="$(pg_scalar "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}' and entry_type='SETTLEMENT';")"
[[ "$LEDGER_AFTER_RETRY" == "1" ]] || { echo "Repeated reconciliation duplicated ledger rows: $LEDGER_AFTER_RETRY"; exit 1; }

echo "==> 7. Wait for mock-sct-inst to recover to two ready replicas"
oc rollout status deployment/mock-sct-inst -n "$PROJECT" --timeout=240s >/dev/null
READY="$(oc get deployment mock-sct-inst -n "$PROJECT" -o jsonpath='{.status.readyReplicas}')"
[[ "${READY:-0}" -ge 2 ]] || { echo "mock-sct-inst did not recover to 2 ready replicas"; exit 1; }

echo "==> 8. Full V5 business/observability regression after SCT Inst failover"
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "V6 OK (phase B4): mock-sct-inst settlement state is shared in PostgreSQL; the pod that accepted TIMEOUT_AFTER_SETTLEMENT was deleted, a different pod reconciled the same payment from UNKNOWN to SETTLED with the same settlementId, the rail row and settlement ledger remained single, the deployment recovered to two replicas, and the full V5 regression passed afterward. This validates pod-level SCT Inst mock failover on CRC; PostgreSQL remains the shared-state dependency and CRC remains single-node."
