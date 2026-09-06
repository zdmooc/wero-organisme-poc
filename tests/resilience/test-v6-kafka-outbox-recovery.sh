#!/usr/bin/env bash
set -euo pipefail

PROJECT="wero-poc"
GITOPS_NS="openshift-gitops"
APP="wero-poc-crc"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHAOS_POLICY="v6-chaos-deny-kafka"

cleanup() {
  oc delete networkpolicy "$CHAOS_POLICY" -n "$PROJECT" --ignore-not-found >/dev/null 2>&1 || true
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
  echo "Argo CD must be Synced/Healthy before Kafka chaos (sync=$SYNC health=$HEALTH)"
  exit 1
}
[[ "$(oc get deployment kafka -n "$PROJECT" -o jsonpath='{.spec.replicas}')" == "1" ]] || {
  echo "Kafka/Redpanda must remain a single-replica SPOF for this test"
  exit 1
}
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "==> 2. Refresh demo credentials for the chaos transaction"
refresh_demo_tokens
GATEWAY_HOST="$(oc get route api-gateway -n "$PROJECT" -o jsonpath='{.spec.host}')"

echo "==> 3. Isolate Kafka deterministically with a temporary NetworkPolicy"
cat <<'EOF' | oc apply -n "$PROJECT" -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: v6-chaos-deny-kafka
  labels:
    chaos.mayabanque.io/scenario: kafka-outage
spec:
  podSelector:
    matchLabels:
      app: kafka
  policyTypes:
    - Ingress
  ingress: []
EOF
sleep 3

echo "==> 4. Commit a SETTLED payment while Kafka is unreachable"
STAMP="$(date +%s)"
CORR_ID="V6-KAFKA-${STAMP}"
PAYMENT_ID="PAY-V6-KAFKA-${STAMP}"
IDEM_KEY="idem-v6-kafka-${STAMP}"
PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":6150,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\"}"
CONSENT_PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":6150,\"currency\":\"EUR\",\"creditorAlias\":\"+33630000002\"}"

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
echo "$PAYMENT_JSON" | grep -q '"status":"SETTLED"' || exit 1

PAYMENT_STATUS="$(pg_scalar "select status from payments where payment_id='${PAYMENT_ID}';")"
LEDGER_COUNT="$(pg_scalar "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}';")"
[[ "$PAYMENT_STATUS" == "SETTLED" ]] || { echo "Payment did not commit while Kafka was unavailable"; exit 1; }
[[ "${LEDGER_COUNT:-0}" -ge 1 ]] || { echo "Ledger did not commit while Kafka was unavailable"; exit 1; }

echo "==> 5. Prove transactional outbox backlog accumulated"
BACKLOG_OBSERVED=false
PENDING_COUNT=0
FAILED_ATTEMPTS=0
for _ in $(seq 1 30); do
  PENDING_COUNT="$(pg_scalar "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}' and published_at is null;")"
  FAILED_ATTEMPTS="$(pg_scalar "select coalesce(sum(publish_attempts),0) from outbox_events where aggregate_id='${PAYMENT_ID}' and published_at is null;")"
  if [[ "${PENDING_COUNT:-0}" -ge 1 && "${FAILED_ATTEMPTS:-0}" -ge 1 ]]; then
    BACKLOG_OBSERVED=true
    break
  fi
  sleep 2
done
[[ "$BACKLOG_OBSERVED" == "true" ]] || {
  echo "Expected an unpublished outbox backlog with at least one failed Kafka publish attempt"
  exit 1
}
AUDIT_BEFORE="$(pg_scalar "select count(*) from payment_audit_events where payment_id='${PAYMENT_ID}';")"
echo "business committed during outage: payment=$PAYMENT_STATUS ledger=$LEDGER_COUNT pendingOutbox=$PENDING_COUNT failedAttempts=$FAILED_ATTEMPTS auditRowsBeforeRecovery=$AUDIT_BEFORE"

echo "==> 6. Restore Kafka connectivity and measure outbox drain"
RECOVERY_START="$(date +%s)"
oc delete networkpolicy "$CHAOS_POLICY" -n "$PROJECT" --ignore-not-found >/dev/null

DRAINED=false
for _ in $(seq 1 90); do
  TOTAL_OUTBOX="$(pg_scalar "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}';")"
  PENDING_COUNT="$(pg_scalar "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}' and published_at is null;")"
  PUBLISHED_COUNT="$(pg_scalar "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}' and published_at is not null;")"
  if [[ "$TOTAL_OUTBOX" == "3" && "$PENDING_COUNT" == "0" && "$PUBLISHED_COUNT" == "3" ]]; then
    DRAINED=true
    break
  fi
  sleep 2
done
[[ "$DRAINED" == "true" ]] || {
  echo "Outbox did not fully drain after Kafka connectivity returned"
  exit 1
}
DRAIN_SECONDS="$(( $(date +%s) - RECOVERY_START ))"
echo "outbox drained 3/3 events in ${DRAIN_SECONDS}s"

echo "==> 7. Verify audit catches up exactly once logically"
AUDIT_READY=false
for _ in $(seq 1 60); do
  AUDIT_COUNT="$(pg_scalar "select count(*) from payment_audit_events where payment_id='${PAYMENT_ID}';")"
  DISTINCT_TYPES="$(pg_scalar "select count(distinct event_type) from payment_audit_events where payment_id='${PAYMENT_ID}';")"
  if [[ "$AUDIT_COUNT" == "3" && "$DISTINCT_TYPES" == "3" ]]; then
    AUDIT_READY=true
    break
  fi
  sleep 2
done
[[ "$AUDIT_READY" == "true" ]] || {
  echo "Audit did not converge to exactly three logical payment events"
  pg_scalar "select event_type, count(*) from payment_audit_events where payment_id='${PAYMENT_ID}' group by event_type order by event_type;" || true
  exit 1
}
for EVENT_TYPE in PAYMENT_CREATED PAYMENT_PROCESSING PAYMENT_SETTLED; do
  COUNT="$(pg_scalar "select count(*) from payment_audit_events where payment_id='${PAYMENT_ID}' and event_type='${EVENT_TYPE}';")"
  [[ "$COUNT" == "1" ]] || { echo "$EVENT_TYPE audit count=$COUNT, expected 1"; exit 1; }
done
echo "audit caught up with exactly one logical CREATED/PROCESSING/SETTLED event"

echo "==> 8. Full V5 business/observability regression after Kafka recovery"
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "V6 OK (phase B2): a SETTLED payment and ledger committed while Kafka was isolated, unpublished outbox rows accumulated with failed publish attempts, Kafka connectivity recovery drained all 3 events in ${DRAIN_SECONDS}s, audit converged to exactly one logical CREATED/PROCESSING/SETTLED event, and the full V5 regression passed afterward. This validates outbox buffering/replay on CRC; it does not make the single ephemeral Redpanda broker HA or prove broker RPO=0."
