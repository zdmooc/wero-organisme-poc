#!/usr/bin/env bash
set -euo pipefail

: "${ALICE_TOKEN:?Set ALICE_TOKEN before running this test}"
: "${AUDITOR_TOKEN:?Set AUDITOR_TOKEN before running this test}"
: "${SCA_CODE:?Set SCA_CODE before running this test}"

PAYMENT_HOST="${1:-$(oc get route payment-service -n wero-poc -o jsonpath='{.spec.host}')}"
AUDIT_HOST="${2:-$(oc get route event-audit-service -n wero-poc -o jsonpath='{.spec.host}')}"
STAMP="$(date +%s)"
PAYMENT_ID="PAY-V3-${STAMP}"
IDEM_KEY="idem-v3-${STAMP}"
PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":3750,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\"}"
CONSENT_PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":3750,\"currency\":\"EUR\",\"creditorAlias\":\"+33630000002\"}"

echo "==> 1. No JWT: payment endpoint must return 401"
HTTP="$(curl -sS -o /tmp/v3-no-jwt.json -w '%{http_code}' -X POST \
  "http://${PAYMENT_HOST}/payments/single-immediate" \
  -H 'Content-Type: application/json' -H "Idempotency-Key: ${IDEM_KEY}" -d "$PAYLOAD")"
[[ "$HTTP" == "401" ]] || { echo "Expected 401, got $HTTP"; exit 1; }

echo "==> 2. Read-only identity cannot create a consent"
HTTP="$(curl -sS -o /tmp/v3-forbidden.json -w '%{http_code}' -X POST \
  "http://${PAYMENT_HOST}/consents" \
  -H "Authorization: Bearer ${AUDITOR_TOKEN}" -H 'Content-Type: application/json' -d "$CONSENT_PAYLOAD")"
[[ "$HTTP" == "403" ]] || { echo "Expected 403, got $HTTP"; exit 1; }

echo "==> 3. Create consent -> PENDING_SCA"
CONSENT_JSON="$(curl -sS -X POST "http://${PAYMENT_HOST}/consents" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H 'Content-Type: application/json' -d "$CONSENT_PAYLOAD")"
echo "$CONSENT_JSON"
CONSENT_ID="$(echo "$CONSENT_JSON" | sed -n 's/.*"consentId":"\([^"]*\)".*/\1/p')"
[[ -n "$CONSENT_ID" ]] || { echo "consentId missing"; exit 1; }
echo "$CONSENT_JSON" | grep -q '"status":"PENDING_SCA"'

echo "==> 4. Payment before SCA -> 403"
HTTP="$(curl -sS -o /tmp/v3-before-sca.json -w '%{http_code}' -X POST \
  "http://${PAYMENT_HOST}/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "Idempotency-Key: ${IDEM_KEY}" \
  -H "X-Consent-Id: ${CONSENT_ID}" -H 'Content-Type: application/json' -d "$PAYLOAD")"
[[ "$HTTP" == "403" ]] || { echo "Expected 403 before SCA, got $HTTP"; exit 1; }

echo "==> 5. SCA -> AUTHORIZED"
SCA_JSON="$(curl -sS -X POST "http://${PAYMENT_HOST}/consents/${CONSENT_ID}/sca" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"code\":\"${SCA_CODE}\"}")"
echo "$SCA_JSON"
echo "$SCA_JSON" | grep -q '"status":"AUTHORIZED"'

echo "==> 6. Authorized payment -> SETTLED"
PAYMENT_JSON="$(curl -sS -X POST "http://${PAYMENT_HOST}/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "Idempotency-Key: ${IDEM_KEY}" \
  -H "X-Consent-Id: ${CONSENT_ID}" -H 'Content-Type: application/json' -d "$PAYLOAD")"
echo "$PAYMENT_JSON"
echo "$PAYMENT_JSON" | grep -q '"status":"SETTLED"'

echo "==> 7. Replay remains idempotent"
curl -sS -i -X POST "http://${PAYMENT_HOST}/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "Idempotency-Key: ${IDEM_KEY}" \
  -H 'Content-Type: application/json' -d "$PAYLOAD"
echo

echo "==> 8. Payment persists consentId"
DETAILS="$(curl -sS "http://${PAYMENT_HOST}/payments/${PAYMENT_ID}" -H "Authorization: Bearer ${ALICE_TOKEN}")"
echo "$DETAILS"
echo "$DETAILS" | grep -q "\"consentId\":\"${CONSENT_ID}\""

echo "==> 9. Protected Kafka audit"
sleep 4
AUDIT_JSON="$(curl -sS "http://${AUDIT_HOST}/audit/events/${PAYMENT_ID}" -H "Authorization: Bearer ${AUDITOR_TOKEN}")"
echo "$AUDIT_JSON"
echo "$AUDIT_JSON" | grep -q 'PAYMENT_SETTLED'

echo "V3A OK: JWT/RBAC -> consent -> SCA -> payment -> Kafka -> protected audit."
