#!/usr/bin/env bash
set -euo pipefail

PROJECT="wero-poc"
GITOPS_NS="openshift-gitops"
APP="wero-poc-crc"
SELF_HEAL_SUSPENDED=false

set_self_heal() {
  local value="$1"
  oc patch application "$APP" -n "$GITOPS_NS" --type=merge \
    -p "{\"spec\":{\"syncPolicy\":{\"automated\":{\"selfHeal\":${value}}}}}" >/dev/null
}

cleanup() {
  set +e
  oc scale deployment/mock-sct-inst -n "$PROJECT" --replicas=2 >/dev/null 2>&1 || true
  oc scale deployment/api-gateway -n "$PROJECT" --replicas=2 >/dev/null 2>&1 || true
  if [[ "$SELF_HEAL_SUSPENDED" == "true" ]]; then
    set_self_heal true >/dev/null 2>&1 || true
  fi
  oc rollout status deployment/mock-sct-inst -n "$PROJECT" --timeout=240s >/dev/null 2>&1 || true
  oc rollout status deployment/api-gateway -n "$PROJECT" --timeout=240s >/dev/null 2>&1 || true
  oc annotate application "$APP" -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  unset ALICE_TOKEN SCA_CODE
}
trap cleanup EXIT

pg_scalar() {
  local sql="$1"
  oc exec -n "$PROJECT" deployment/postgresql -- sh -lc \
    "psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -Atc \"$sql\"" \
    2>/dev/null | tr -d '\r'
}

refresh_demo_auth() {
  local kc_host alice_password token_json
  kc_host="$(oc get route keycloak -n "$PROJECT" -o jsonpath='{.spec.host}')"
  alice_password="$(oc get secret wero-v3-demo-users -n "$PROJECT" -o jsonpath='{.data.ALICE_PASSWORD}' | base64 -d)"
  token_json="$(curl -sS -X POST \
    "http://${kc_host}/realms/mayabanque/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=mayabanque-cli' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode 'username=alice' \
    --data-urlencode "password=${alice_password}")"
  export ALICE_TOKEN="$(printf '%s' "$token_json" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  export SCA_CODE="$(oc get secret wero-v3-app -n "$PROJECT" -o jsonpath='{.data.SCA_DEMO_CODE}' | base64 -d)"
  unset alice_password token_json
  [[ -n "$ALICE_TOKEN" && -n "$SCA_CODE" ]] || { echo "Unable to refresh demo auth"; exit 1; }
  echo "fresh demo JWT/SCA acquired (values not printed)"
}

wait_argo() {
  local sync health
  for _ in $(seq 1 60); do
    sync="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    [[ "$sync" == "Synced" && "$health" == "Healthy" ]] && return 0
    sleep 5
  done
  return 1
}

wait_zero_pods() {
  local label="$1"
  for _ in $(seq 1 30); do
    [[ "$(oc get pods -n "$PROJECT" -l "app=${label}" --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] && return 0
    sleep 2
  done
  return 1
}

create_authorized_consent() {
  local gateway_host="$1" payment_id="$2" amount="$3" corr="$4"
  local consent_json consent_id sca_json
  consent_json="$(curl -sS -X POST "http://${gateway_host}/api/consents" \
    -H "Authorization: Bearer ${ALICE_TOKEN}" \
    -H "X-Correlation-Id: ${corr}" \
    -H 'Content-Type: application/json' \
    -d "{\"paymentId\":\"${payment_id}\",\"amountCents\":${amount},\"currency\":\"EUR\",\"creditorAlias\":\"+33630000002\"}")"
  consent_id="$(echo "$consent_json" | sed -n 's/.*"consentId":"\([^"]*\)".*/\1/p')"
  [[ -n "$consent_id" ]] || { echo "consentId missing" >&2; exit 1; }
  sca_json="$(curl -sS -X POST "http://${gateway_host}/api/consents/${consent_id}/sca" \
    -H "Authorization: Bearer ${ALICE_TOKEN}" \
    -H "X-Correlation-Id: ${corr}" \
    -H 'Content-Type: application/json' \
    -d "{\"code\":\"${SCA_CODE}\"}")"
  echo "$sca_json" | grep -q '"status":"AUTHORIZED"' || { echo "$sca_json" >&2; exit 1; }
  printf '%s' "$consent_id"
}

echo "==> 1. Preconditions"
SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}')"
HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}')"
[[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] || { echo "Argo must be Synced/Healthy"; exit 1; }
[[ "$(oc get deployment mock-sct-inst -n "$PROJECT" -o jsonpath='{.status.readyReplicas}')" == "2" ]] || exit 1
[[ "$(oc get deployment api-gateway -n "$PROJECT" -o jsonpath='{.status.readyReplicas}')" == "2" ]] || exit 1

GATEWAY_HOST="$(oc get route api-gateway -n "$PROJECT" -o jsonpath='{.spec.host}')"
STAMP="$(date +%s)"

# ---------------------------------------------------------------------------
# B8-SCT: full SCT Inst outage while Wero/EPI remains available.
# ---------------------------------------------------------------------------
echo "==> 2. SCT Inst degraded mode: prepare authorized payment"
refresh_demo_auth
SCT_PAYMENT="PAY-V6-B8-SCT-${STAMP}"
SCT_IDEM="idem-v6-b8-sct-${STAMP}"
SCT_CORR="V6-B8-SCT-${STAMP}"
SCT_PAYLOAD="{\"paymentId\":\"${SCT_PAYMENT}\",\"amountCents\":9650,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\"}"
SCT_CONSENT="$(create_authorized_consent "$GATEWAY_HOST" "$SCT_PAYMENT" 9650 "$SCT_CORR")"

echo "==> 3. Stop both SCT Inst replicas and submit payment"
set_self_heal false
SELF_HEAL_SUSPENDED=true
oc scale deployment/mock-sct-inst -n "$PROJECT" --replicas=0 >/dev/null
wait_zero_pods mock-sct-inst || { echo "mock-sct-inst did not stop"; exit 1; }

SCT_CODE="$(curl -sS --connect-timeout 2 --max-time 12 -o /tmp/v6-b8-sct.json -w '%{http_code}' \
  -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Idempotency-Key: ${SCT_IDEM}" \
  -H "X-Consent-Id: ${SCT_CONSENT}" \
  -H "X-Correlation-Id: ${SCT_CORR}" \
  -H 'Content-Type: application/json' -d "$SCT_PAYLOAD" 2>/dev/null || true)"
SCT_JSON="$(cat /tmp/v6-b8-sct.json 2>/dev/null || true)"
echo "$SCT_JSON"
[[ "$SCT_CODE" == "202" ]] || { echo "Expected SCT outage payment HTTP 202, got $SCT_CODE"; exit 1; }
echo "$SCT_JSON" | grep -q '"status":"UNKNOWN"' || exit 1
[[ "$(pg_scalar "select status from payments where payment_id='${SCT_PAYMENT}';")" == "UNKNOWN" ]] || exit 1
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${SCT_PAYMENT}';")" == "0" ]] || exit 1
[[ "$(pg_scalar "select count(*) from ledger_entries where payment_id='${SCT_PAYMENT}' and entry_type='SETTLEMENT';")" == "0" ]] || exit 1

REPLAY_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "Idempotency-Key: ${SCT_IDEM}" \
  -H "X-Consent-Id: ${SCT_CONSENT}" -H "X-Correlation-Id: ${SCT_CORR}-REPLAY" \
  -H 'Content-Type: application/json' -d "$SCT_PAYLOAD")"
echo "$REPLAY_JSON" | grep -q '"status":"UNKNOWN"' || exit 1
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${SCT_PAYMENT}';")" == "0" ]] || exit 1

echo "==> 4. Restore SCT Inst, reconcile, then controlled recovery"
SCT_RECOVERY_START="$(date +%s)"
oc scale deployment/mock-sct-inst -n "$PROJECT" --replicas=2 >/dev/null
oc rollout status deployment/mock-sct-inst -n "$PROJECT" --timeout=240s >/dev/null
set_self_heal true
SELF_HEAL_SUSPENDED=false
oc annotate application "$APP" -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
wait_argo || { echo "Argo did not recover after SCT Inst outage"; exit 1; }
SCT_RTO="$(( $(date +%s) - SCT_RECOVERY_START ))"
refresh_demo_auth

RECON_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/${SCT_PAYMENT}/reconcile" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${SCT_CORR}-RECON")"
echo "$RECON_JSON"
echo "$RECON_JSON" | grep -q '"railStatus":"NOT_FOUND"' || exit 1
echo "$RECON_JSON" | grep -q '"afterStatus":"UNKNOWN"' || exit 1

RECOVER_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/${SCT_PAYMENT}/recover" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${SCT_CORR}-RECOVER" \
  -H 'Content-Type: application/json' -d '{"confirmation":"RESUBMIT_AFTER_RAIL_NOT_FOUND"}')"
echo "$RECOVER_JSON"
echo "$RECOVER_JSON" | grep -q '"action":"RESUBMITTED"' || exit 1
echo "$RECOVER_JSON" | grep -q '"afterStatus":"SETTLED"' || exit 1
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${SCT_PAYMENT}';")" == "1" ]] || exit 1
[[ "$(pg_scalar "select count(*) from ledger_entries where payment_id='${SCT_PAYMENT}' and entry_type='SETTLEMENT';")" == "1" ]] || exit 1

# ---------------------------------------------------------------------------
# B8-GW: full API Gateway outage. Backend remains isolated by V3B.
# ---------------------------------------------------------------------------
echo "==> 5. API Gateway degraded mode: prepare authorized payment"
GW_PAYMENT="PAY-V6-B8-GW-${STAMP}"
GW_IDEM="idem-v6-b8-gw-${STAMP}"
GW_CORR="V6-B8-GW-${STAMP}"
GW_PAYLOAD="{\"paymentId\":\"${GW_PAYMENT}\",\"amountCents\":9750,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\"}"
GW_CONSENT="$(create_authorized_consent "$GATEWAY_HOST" "$GW_PAYMENT" 9750 "$GW_CORR")"

BASELINE_CODE="$(curl -sS -o /tmp/v6-b8-gw-baseline.json -w '%{http_code}' \
  "http://${GATEWAY_HOST}/api/payments/${SCT_PAYMENT}" -H "Authorization: Bearer ${ALICE_TOKEN}")"
[[ "$BASELINE_CODE" == "200" ]] || exit 1

echo "==> 6. Stop both API Gateway replicas; reads and creates must be unavailable"
set_self_heal false
SELF_HEAL_SUSPENDED=true
oc scale deployment/api-gateway -n "$PROJECT" --replicas=0 >/dev/null
wait_zero_pods api-gateway || { echo "api-gateway did not stop"; exit 1; }

GW_READ_CODE="$(curl -sS --connect-timeout 2 --max-time 8 -o /tmp/v6-b8-gw-read.json -w '%{http_code}' \
  "http://${GATEWAY_HOST}/api/payments/${SCT_PAYMENT}" -H "Authorization: Bearer ${ALICE_TOKEN}" 2>/dev/null || true)"
GW_CREATE_CODE="$(curl -sS --connect-timeout 2 --max-time 8 -o /tmp/v6-b8-gw-create.json -w '%{http_code}' \
  -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "Idempotency-Key: ${GW_IDEM}" \
  -H "X-Consent-Id: ${GW_CONSENT}" -H "X-Correlation-Id: ${GW_CORR}" \
  -H 'Content-Type: application/json' -d "$GW_PAYLOAD" 2>/dev/null || true)"
echo "gateway outage HTTP read=${GW_READ_CODE:-000} create=${GW_CREATE_CODE:-000}"
[[ "$GW_READ_CODE" != "200" ]] || { echo "Read unexpectedly succeeded while gateway was down"; exit 1; }
[[ "$GW_CREATE_CODE" != "200" && "$GW_CREATE_CODE" != "202" ]] || { echo "Create unexpectedly reached backend while gateway was down"; exit 1; }
[[ "$(pg_scalar "select count(*) from payments where payment_id='${GW_PAYMENT}';")" == "0" ]] || { echo "Gateway outage created a payment row"; exit 1; }
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${GW_PAYMENT}';")" == "0" ]] || exit 1
[[ "$(pg_scalar "select count(*) from ledger_entries where payment_id='${GW_PAYMENT}';")" == "0" ]] || exit 1

echo "==> 7. Restore API Gateway and retry the untouched intent"
GW_RECOVERY_START="$(date +%s)"
oc scale deployment/api-gateway -n "$PROJECT" --replicas=2 >/dev/null
oc rollout status deployment/api-gateway -n "$PROJECT" --timeout=240s >/dev/null
set_self_heal true
SELF_HEAL_SUSPENDED=false
oc annotate application "$APP" -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
wait_argo || { echo "Argo did not recover after gateway outage"; exit 1; }
GW_RTO="$(( $(date +%s) - GW_RECOVERY_START ))"
refresh_demo_auth

GW_RESULT="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "Idempotency-Key: ${GW_IDEM}" \
  -H "X-Consent-Id: ${GW_CONSENT}" -H "X-Correlation-Id: ${GW_CORR}-AFTER" \
  -H 'Content-Type: application/json' -d "$GW_PAYLOAD")"
echo "$GW_RESULT"
echo "$GW_RESULT" | grep -q '"status":"SETTLED"' || exit 1
[[ "$(pg_scalar "select count(*) from payments where payment_id='${GW_PAYMENT}';")" == "1" ]] || exit 1
[[ "$(pg_scalar "select count(*) from sct_inst_transfers where payment_id='${GW_PAYMENT}';")" == "1" ]] || exit 1
[[ "$(pg_scalar "select count(*) from ledger_entries where payment_id='${GW_PAYMENT}' and entry_type='SETTLEMENT';")" == "1" ]] || exit 1

wait_argo || exit 1

echo "V6 OK (phase B8): degraded-mode coverage is complete when combined with previously validated B1 PostgreSQL, B2 Kafka/Outbox, B3 Keycloak and B5 Wero/EPI evidence. Full SCT Inst outage produced UNKNOWN with no rail/ledger row, no blind replay, then NOT_FOUND reconciliation and one controlled recovery; SCT Inst recovered in ${SCT_RTO}s. Full API Gateway outage made reads/creates unavailable without backend side effects, then the untouched intent settled once after gateway recovery in ${GW_RTO}s. CRC validates controlled pod/service outages, not node/zone/site HA."