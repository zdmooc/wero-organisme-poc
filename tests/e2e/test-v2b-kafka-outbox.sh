#!/usr/bin/env bash
set -euo pipefail

PAYMENT_HOST="${1:-$(oc get route payment-service -n wero-poc -o jsonpath='{.spec.host}')}"
AUDIT_HOST="${2:-$(oc get route event-audit-service -n wero-poc -o jsonpath='{.spec.host}')}"
SUFFIX="$(date +%s)"

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

wait_for_audit() {
  local payment_id="$1"
  local expected="$2"
  local body=""
  for _ in $(seq 1 25); do
    body="$(curl -sS "http://${AUDIT_HOST}/audit/events/${payment_id}")"
    if [[ "$body" == *"$expected"* ]]; then
      echo "$body"
      return 0
    fi
    sleep 1
  done
  echo "$body"
  return 1
}

wait_for_published_outbox() {
  local payment_id="$1"
  local body=""
  for _ in $(seq 1 25); do
    body="$(curl -sS "http://${PAYMENT_HOST}/outbox/${payment_id}")"
    if [[ "$body" == *"PAYMENT_SETTLED"* && "$body" != *'"publishedAt":null'* ]]; then
      echo "$body"
      return 0
    fi
    sleep 1
  done
  echo "$body"
  return 1
}

echo "==> 1. Nominal payment creates transactional outbox rows"
PAY1="PAY-V2B-${SUFFIX}"
KEY1="idem-v2b-${SUFFIX}"
RESP1="$(curl -sS -X POST "http://${PAYMENT_HOST}/payments/single-immediate" \
  -H "Idempotency-Key: ${KEY1}" \
  -H 'Content-Type: application/json' \
  -d "{\"paymentId\":\"${PAY1}\",\"amountCents\":4200,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\",\"simulateMode\":null}")"
echo "$RESP1"
[[ "$RESP1" == *'"status":"SETTLED"'* ]] || fail "nominal payment is not SETTLED"

echo "==> 2. Outbox publisher sends CREATED / PROCESSING / SETTLED"
OUTBOX1="$(wait_for_published_outbox "$PAY1")" || fail "outbox rows were not published"
echo "$OUTBOX1"
[[ "$OUTBOX1" == *"PAYMENT_CREATED"* ]] || fail "PAYMENT_CREATED missing"
[[ "$OUTBOX1" == *"PAYMENT_PROCESSING"* ]] || fail "PAYMENT_PROCESSING missing"
[[ "$OUTBOX1" == *"PAYMENT_SETTLED"* ]] || fail "PAYMENT_SETTLED missing"

COUNT_BEFORE="$(printf '%s' "$OUTBOX1" | grep -o '"eventType"' | wc -l | tr -d ' ')"

echo "==> 3. Kafka consumer receives and persists the events"
AUDIT1="$(wait_for_audit "$PAY1" "PAYMENT_SETTLED")" || fail "audit consumer did not receive SETTLED"
echo "$AUDIT1"
[[ "$AUDIT1" == *"PAYMENT_CREATED"* ]] || fail "audit PAYMENT_CREATED missing"
[[ "$AUDIT1" == *"PAYMENT_PROCESSING"* ]] || fail "audit PAYMENT_PROCESSING missing"
[[ "$AUDIT1" == *"PAYMENT_SETTLED"* ]] || fail "audit PAYMENT_SETTLED missing"

echo "==> 4. Idempotent replay must not create new outbox events"
curl -sS -X POST "http://${PAYMENT_HOST}/payments/single-immediate" \
  -H "Idempotency-Key: ${KEY1}" \
  -H 'Content-Type: application/json' \
  -d "{\"paymentId\":\"${PAY1}\",\"amountCents\":4200,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\",\"simulateMode\":null}"
echo
sleep 2
OUTBOX_REPLAY="$(curl -sS "http://${PAYMENT_HOST}/outbox/${PAY1}")"
COUNT_AFTER="$(printf '%s' "$OUTBOX_REPLAY" | grep -o '"eventType"' | wc -l | tr -d ' ')"
[[ "$COUNT_BEFORE" == "$COUNT_AFTER" ]] || fail "idempotent replay generated extra outbox events"

echo "==> 5. UNKNOWN -> reconciliation emits UNKNOWN / RECONCILED / SETTLED"
PAY2="PAY-V2B-UNKNOWN-${SUFFIX}"
KEY2="idem-v2b-unknown-${SUFFIX}"
RESP2="$(curl -sS -X POST "http://${PAYMENT_HOST}/payments/single-immediate" \
  -H "Idempotency-Key: ${KEY2}" \
  -H 'Content-Type: application/json' \
  -d "{\"paymentId\":\"${PAY2}\",\"amountCents\":9900,\"currency\":\"EUR\",\"debtorAlias\":\"+33640000001\",\"creditorAlias\":\"+33640000002\",\"simulateMode\":\"TIMEOUT_AFTER_SETTLEMENT\"}")"
echo "$RESP2"
[[ "$RESP2" == *'"status":"UNKNOWN"'* ]] || fail "timeout scenario is not UNKNOWN"

RECON="$(curl -sS -X POST "http://${PAYMENT_HOST}/payments/${PAY2}/reconcile")"
echo "$RECON"
[[ "$RECON" == *'"afterStatus":"SETTLED"'* ]] || fail "reconciliation did not converge to SETTLED"

AUDIT2="$(wait_for_audit "$PAY2" "PAYMENT_RECONCILED")" || fail "reconciliation event not consumed"
echo "$AUDIT2"
[[ "$AUDIT2" == *"PAYMENT_UNKNOWN"* ]] || fail "PAYMENT_UNKNOWN missing from audit"
[[ "$AUDIT2" == *"PAYMENT_RECONCILED"* ]] || fail "PAYMENT_RECONCILED missing from audit"
[[ "$AUDIT2" == *"PAYMENT_SETTLED"* ]] || fail "reconciled PAYMENT_SETTLED missing from audit"

echo
echo "V2B OK: PostgreSQL transaction -> outbox -> Kafka API -> audit consumer, with idempotence and UNKNOWN reconciliation."
