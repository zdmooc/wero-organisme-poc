#!/usr/bin/env bash
set -euo pipefail

: "${ALICE_TOKEN:?Set a fresh ALICE_TOKEN before running B7}"
: "${B7_PAYMENT_ID:?Set B7_PAYMENT_ID to a pre-rail UNKNOWN payment produced by B5}"

PROJECT="wero-poc"
GITOPS_NS="openshift-gitops"
APP="wero-poc-crc"
CONCURRENCY="${B7_CONCURRENCY:-8}"
PAYMENT_ID="$B7_PAYMENT_ID"
STAMP="$(date +%s)"
CORR_ID="V6-B7-CONCURRENT-${STAMP}"
TMPDIR_B7="/tmp/v6-b7-${STAMP}"
mkdir -p "$TMPDIR_B7"

pg_scalar() {
  local sql="$1"
  oc exec -n "$PROJECT" deployment/postgresql -- sh -lc \
    "psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -Atc \"$sql\"" \
    2>/dev/null | tr -d '\r'
}

assert_count() {
  local expected="$1" sql="$2" label="$3" actual
  actual="$(pg_scalar "$sql")"
  [[ "$actual" == "$expected" ]] || {
    echo "Expected ${label}=${expected}, got ${actual}"
    exit 1
  }
}

echo "==> 1. Preconditions"
SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}')"
HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}')"
[[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] || { echo "Argo must be Synced/Healthy"; exit 1; }
[[ "$(oc get deployment payment-service -n "$PROJECT" -o jsonpath='{.status.readyReplicas}')" == "2" ]] || { echo "payment-service must be 2/2"; exit 1; }
[[ "$(oc get deployment mock-wero -n "$PROJECT" -o jsonpath='{.status.readyReplicas}')" == "2" ]] || { echo "mock-wero must be 2/2"; exit 1; }
[[ "$(pg_scalar "select status from payments where payment_id='${PAYMENT_ID}';")" == "UNKNOWN" ]] || { echo "B7 payment must start UNKNOWN"; exit 1; }
assert_count 0 "select count(*) from sct_inst_transfers where payment_id='${PAYMENT_ID}';" "rail rows before B7"
assert_count 0 "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}' and entry_type='SETTLEMENT';" "settlement ledger before B7"

GATEWAY_HOST="$(oc get route api-gateway -n "$PROJECT" -o jsonpath='{.spec.host}')"
RECON_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/reconcile" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}-PRECHECK")"
echo "$RECON_JSON"
echo "$RECON_JSON" | grep -q '"railStatus":"NOT_FOUND"' || exit 1
echo "$RECON_JSON" | grep -q '"afterStatus":"UNKNOWN"' || exit 1

echo "==> 2. Launch ${CONCURRENCY} simultaneous controlled recoveries"
PIDS=()
for i in $(seq 1 "$CONCURRENCY"); do
  (
    while [[ ! -f "$TMPDIR_B7/start" ]]; do sleep 0.05; done
    code="$(curl -sS --connect-timeout 2 --max-time 30 \
      -o "$TMPDIR_B7/response-${i}.json" -w '%{http_code}' \
      -X POST "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/recover" \
      -H "Authorization: Bearer ${ALICE_TOKEN}" \
      -H "X-Correlation-Id: ${CORR_ID}-${i}" \
      -H 'Content-Type: application/json' \
      -d '{"confirmation":"RESUBMIT_AFTER_RAIL_NOT_FOUND"}' \
      2>"$TMPDIR_B7/curl-${i}.err" || true)"
    printf '%s' "$code" > "$TMPDIR_B7/code-${i}.txt"
  ) &
  PIDS+=("$!")
done

touch "$TMPDIR_B7/start"
for pid in "${PIDS[@]}"; do wait "$pid"; done

for i in $(seq 1 "$CONCURRENCY"); do
  code="$(cat "$TMPDIR_B7/code-${i}.txt" 2>/dev/null || true)"
  body="$(cat "$TMPDIR_B7/response-${i}.json" 2>/dev/null || true)"
  echo "recovery[$i] HTTP=${code} ${body}"
  [[ "$code" == "200" || "$code" == "202" ]] || exit 1
  echo "$body" | grep -q '"action":"' || exit 1
done

ACTIONS_FILE="$TMPDIR_B7/actions.txt"
grep -h -o '"action":"[^"]*"' "$TMPDIR_B7"/response-*.json > "$ACTIONS_FILE"
TOTAL_ACTIONS="$(wc -l < "$ACTIONS_FILE" | tr -d ' ')"
RESUBMITTED="$(grep -c '^"action":"RESUBMITTED"$' "$ACTIONS_FILE" || true)"
CLAIMED="$(grep -c '^"action":"RECOVERY_ALREADY_CLAIMED"$' "$ACTIONS_FILE" || true)"
IN_PROGRESS="$(grep -c '^"action":"RECOVERY_ALREADY_IN_PROGRESS"$' "$ACTIONS_FILE" || true)"
ALREADY_FINAL="$(grep -c '^"action":"ALREADY_FINAL"$' "$ACTIONS_FILE" || true)"
RECONCILED="$(grep -c '^"action":"RECONCILED_WITHOUT_RESUBMIT"$' "$ACTIONS_FILE" || true)"
SAFE_LOSERS="$((CLAIMED + IN_PROGRESS + ALREADY_FINAL + RECONCILED))"

echo "actions: total=${TOTAL_ACTIONS} resubmitted=${RESUBMITTED} alreadyClaimed=${CLAIMED} inProgress=${IN_PROGRESS} alreadyFinal=${ALREADY_FINAL} reconciledWithoutResubmit=${RECONCILED}"
[[ "$TOTAL_ACTIONS" == "$CONCURRENCY" ]] || exit 1
[[ "$RESUBMITTED" == "1" ]] || { echo "Expected exactly one RESUBMITTED"; exit 1; }
[[ "$SAFE_LOSERS" == "$((CONCURRENCY - 1))" ]] || { echo "Unexpected concurrent action"; cat "$ACTIONS_FILE"; exit 1; }

echo "==> 3. Verify exclusion and business invariants"
[[ "$(pg_scalar "select status from payments where payment_id='${PAYMENT_ID}';")" == "SETTLED" ]] || exit 1
assert_count 1 "select count(*) from sct_inst_transfers where payment_id='${PAYMENT_ID}';" "rail rows"
assert_count 1 "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}' and entry_type='SETTLEMENT';" "settlement ledger"
assert_count 1 "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}' and event_type='PAYMENT_RECOVERY_STARTED';" "PAYMENT_RECOVERY_STARTED"
assert_count 1 "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}' and event_type='PAYMENT_RECOVERED';" "PAYMENT_RECOVERED"
assert_count 1 "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}' and event_type='PAYMENT_SETTLED';" "PAYMENT_SETTLED"
assert_count 0 "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}' and event_type='PAYMENT_RECOVERY_FAILED';" "PAYMENT_RECOVERY_FAILED"

echo "V6 OK (phase B7): ${CONCURRENCY} simultaneous recovery requests produced exactly one RESUBMITTED and ${SAFE_LOSERS} safe losing calls, including an optional rail reconciliation that observes the winner's settlement without resubmitting; final SETTLED state has one rail row, one settlement ledger, one recovery-started event and one recovered event. This validates concurrent database-claim exclusion on CRC, not node/zone/site HA."
