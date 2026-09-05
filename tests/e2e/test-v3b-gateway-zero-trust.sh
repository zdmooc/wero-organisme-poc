#!/usr/bin/env bash
set -euo pipefail

: "${ALICE_TOKEN:?Set ALICE_TOKEN before running this test}"
: "${AUDITOR_TOKEN:?Set AUDITOR_TOKEN before running this test}"
: "${SCA_CODE:?Set SCA_CODE before running this test}"

GATEWAY_HOST="${1:-$(oc get route api-gateway -n wero-poc -o jsonpath='{.spec.host}')}"
STAMP="$(date +%s)"
PAYMENT_ID="PAY-V3B-${STAMP}"
IDEM_KEY="idem-v3b-${STAMP}"
PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":4250,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\"}"
CONSENT_PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":4250,\"currency\":\"EUR\",\"creditorAlias\":\"+33630000002\"}"

echo "==> 1. Only gateway and Keycloak are externally routed"
if oc get route payment-service -n wero-poc >/dev/null 2>&1; then
  echo "ERROR: payment-service must not have an external Route"
  exit 1
fi
if oc get route event-audit-service -n wero-poc >/dev/null 2>&1; then
  echo "ERROR: event-audit-service must not have an external Route"
  exit 1
fi
oc get route api-gateway keycloak -n wero-poc >/dev/null
oc get networkpolicy gateway-only-payment gateway-only-audit -n wero-poc >/dev/null

echo "==> 2. Gateway requires JWT"
HTTP="$(curl -sS -o /tmp/v3b-no-jwt.json -w '%{http_code}' -X POST \
  "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H 'Content-Type: application/json' -H "Idempotency-Key: ${IDEM_KEY}" -d "$PAYLOAD")"
[[ "$HTTP" == "401" ]] || { echo "Expected 401, got $HTTP"; cat /tmp/v3b-no-jwt.json; exit 1; }

echo "==> 3. Read-only JWT is forbidden from creating consent"
HTTP="$(curl -sS -o /tmp/v3b-forbidden.json -w '%{http_code}' -X POST \
  "http://${GATEWAY_HOST}/api/consents" \
  -H "Authorization: Bearer ${AUDITOR_TOKEN}" -H 'Content-Type: application/json' -d "$CONSENT_PAYLOAD")"
[[ "$HTTP" == "403" ]] || { echo "Expected 403, got $HTTP"; cat /tmp/v3b-forbidden.json; exit 1; }

echo "==> 4. Create consent through gateway -> PENDING_SCA"
CONSENT_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/consents" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H 'X-Correlation-Id: V3B-CONSENT' \
  -H 'Content-Type: application/json' -d "$CONSENT_PAYLOAD")"
echo "$CONSENT_JSON"
CONSENT_ID="$(echo "$CONSENT_JSON" | sed -n 's/.*"consentId":"\([^"]*\)".*/\1/p')"
[[ -n "$CONSENT_ID" ]] || { echo "consentId missing"; exit 1; }
echo "$CONSENT_JSON" | grep -q '"status":"PENDING_SCA"'

echo "==> 5. SCA through gateway -> AUTHORIZED"
SCA_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/consents/${CONSENT_ID}/sca" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"code\":\"${SCA_CODE}\"}")"
echo "$SCA_JSON"
echo "$SCA_JSON" | grep -q '"status":"AUTHORIZED"'

echo "==> 6. Authorized payment through gateway -> SETTLED"
PAYMENT_HEADERS="$(mktemp)"
PAYMENT_JSON="$(curl -sS -D "$PAYMENT_HEADERS" -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Idempotency-Key: ${IDEM_KEY}" \
  -H "X-Consent-Id: ${CONSENT_ID}" \
  -H 'X-Correlation-Id: V3B-PAYMENT' \
  -H 'Content-Type: application/json' -d "$PAYLOAD")"
echo "$PAYMENT_JSON"
echo "$PAYMENT_JSON" | grep -q '"status":"SETTLED"'
grep -qi '^x-correlation-id: V3B-PAYMENT' "$PAYMENT_HEADERS"

echo "==> 7. Replay remains idempotent through gateway"
REPLAY_HEADERS="$(mktemp)"
REPLAY_JSON="$(curl -sS -D "$REPLAY_HEADERS" -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Idempotency-Key: ${IDEM_KEY}" \
  -H 'Content-Type: application/json' -d "$PAYLOAD")"
echo "$REPLAY_JSON"
grep -qi '^x-idempotent-replay: true' "$REPLAY_HEADERS"
echo "$REPLAY_JSON" | grep -q '"status":"SETTLED"'

echo "==> 8. Payment details and ledger are reachable only through gateway"
DETAILS="$(curl -sS "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}" -H "Authorization: Bearer ${ALICE_TOKEN}")"
echo "$DETAILS"
echo "$DETAILS" | grep -q "\"consentId\":\"${CONSENT_ID}\""
LEDGER="$(curl -sS "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/ledger" -H "Authorization: Bearer ${ALICE_TOKEN}")"
echo "$LEDGER"
echo "$LEDGER" | grep -q 'SETTLEMENT'

echo "==> 9. Protected Kafka audit through gateway"
sleep 4
AUDIT_JSON="$(curl -sS "http://${GATEWAY_HOST}/api/audit/events/${PAYMENT_ID}" -H "Authorization: Bearer ${AUDITOR_TOKEN}")"
echo "$AUDIT_JSON"
echo "$AUDIT_JSON" | grep -q 'PAYMENT_SETTLED'

echo "V3B OK: single API Gateway -> JWT/RBAC -> token relay -> internal services -> Kafka audit, with backend Routes removed and NetworkPolicy enforced."
