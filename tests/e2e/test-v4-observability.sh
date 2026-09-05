#!/usr/bin/env bash
set -euo pipefail

: "${ALICE_TOKEN:?Set ALICE_TOKEN before running this test}"
: "${AUDITOR_TOKEN:?Set AUDITOR_TOKEN before running this test}"
: "${SCA_CODE:?Set SCA_CODE before running this test}"

PROJECT=wero-poc
GATEWAY_HOST="${1:-$(oc get route api-gateway -n "$PROJECT" -o jsonpath='{.spec.host}')}"
JAEGER_HOST="$(oc get route jaeger -n "$PROJECT" -o jsonpath='{.spec.host}')"
PROM_HOST="$(oc get route prometheus -n "$PROJECT" -o jsonpath='{.spec.host}')"
GRAFANA_HOST="$(oc get route grafana -n "$PROJECT" -o jsonpath='{.spec.host}')"
STAMP="$(date +%s)"
CORR_ID="V4-${STAMP}"
PAYMENT_ID="PAY-V4-${STAMP}"
IDEM_KEY="idem-v4-${STAMP}"
PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":5150,\"currency\":\"EUR\",\"debtorAlias\":\"+33630000001\",\"creditorAlias\":\"+33630000002\"}"
CONSENT_PAYLOAD="{\"paymentId\":\"${PAYMENT_ID}\",\"amountCents\":5150,\"currency\":\"EUR\",\"creditorAlias\":\"+33630000002\"}"

echo "==> 1. Observability routes and V3B isolation"
oc get route api-gateway keycloak jaeger prometheus grafana -n "$PROJECT" >/dev/null
! oc get route payment-service -n "$PROJECT" >/dev/null 2>&1
! oc get route event-audit-service -n "$PROJECT" >/dev/null 2>&1
oc get networkpolicy gateway-only-payment gateway-only-audit -n "$PROJECT" >/dev/null

echo "==> 2. Create consent with correlation ID"
CONSENT_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/consents" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}" \
  -H 'Content-Type: application/json' -d "$CONSENT_PAYLOAD")"
echo "$CONSENT_JSON"
CONSENT_ID="$(echo "$CONSENT_JSON" | sed -n 's/.*"consentId":"\([^"]*\)".*/\1/p')"
[[ -n "$CONSENT_ID" ]] || { echo "consentId missing"; exit 1; }
echo "$CONSENT_JSON" | grep -q '"status":"PENDING_SCA"'

echo "==> 3. SCA -> AUTHORIZED"
SCA_JSON="$(curl -sS -X POST "http://${GATEWAY_HOST}/api/consents/${CONSENT_ID}/sca" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}" \
  -H 'Content-Type: application/json' -d "{\"code\":\"${SCA_CODE}\"}")"
echo "$SCA_JSON"
echo "$SCA_JSON" | grep -q '"status":"AUTHORIZED"'

echo "==> 4. Payment -> SETTLED and trace ID returned"
HEADERS="$(mktemp)"
PAYMENT_JSON="$(curl -sS -D "$HEADERS" -X POST "http://${GATEWAY_HOST}/api/payments/single-immediate" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "Idempotency-Key: ${IDEM_KEY}" \
  -H "X-Consent-Id: ${CONSENT_ID}" -H "X-Correlation-Id: ${CORR_ID}" \
  -H 'Content-Type: application/json' -d "$PAYLOAD")"
echo "$PAYMENT_JSON"
echo "$PAYMENT_JSON" | grep -q '"status":"SETTLED"'
grep -qi "^x-correlation-id: ${CORR_ID}" "$HEADERS"
TRACE_ID="$(grep -i '^x-trace-id:' "$HEADERS" | tail -1 | tr -d '\r' | awk '{print $2}')"
[[ "$TRACE_ID" =~ ^[0-9a-f]{32}$ ]] || { echo "Invalid or missing X-Trace-Id: $TRACE_ID"; cat "$HEADERS"; exit 1; }
echo "traceId=$TRACE_ID correlationId=$CORR_ID paymentId=$PAYMENT_ID"

echo "==> 5. Ledger and Kafka audit preserve business context"
LEDGER="$(curl -sS "http://${GATEWAY_HOST}/api/payments/${PAYMENT_ID}/ledger" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}")"
echo "$LEDGER"
echo "$LEDGER" | grep -q 'SETTLEMENT'

sleep 6
AUDIT_JSON="$(curl -sS "http://${GATEWAY_HOST}/api/audit/events/${PAYMENT_ID}" \
  -H "Authorization: Bearer ${AUDITOR_TOKEN}" -H "X-Correlation-Id: ${CORR_ID}")"
echo "$AUDIT_JSON"
echo "$AUDIT_JSON" | grep -q 'PAYMENT_SETTLED'
echo "$AUDIT_JSON" | grep -q "\"correlationId\":\"${CORR_ID}\""
echo "$AUDIT_JSON" | grep -q "\"traceId\":\"${TRACE_ID}\""

echo "==> 6. Prometheus sees all critical targets and business metric"
for job in api-gateway payment-service consumer-psp event-audit-service mock-wero mock-sct-inst; do
  UP="$(curl -sS -G "http://${PROM_HOST}/api/v1/query" --data-urlencode "query=up{job=\"${job}\"}")"
  echo "$UP" | grep -q '"status":"success"'
  echo "$UP" | grep -q '"value"'
done
METRIC="$(curl -sS -G "http://${PROM_HOST}/api/v1/query" \
  --data-urlencode 'query=wero_payments_total{status="SETTLED"}')"
echo "$METRIC"
echo "$METRIC" | grep -q '"status":"success"'
echo "$METRIC" | grep -q '"value"'

echo "==> 7. Jaeger contains the synchronous and asynchronous E2E trace"
TRACE_JSON=""
for i in 1 2 3 4 5 6; do
  TRACE_JSON="$(curl -sS "http://${JAEGER_HOST}/api/traces/${TRACE_ID}" || true)"
  if echo "$TRACE_JSON" | grep -q "$TRACE_ID"; then break; fi
  sleep 2
done
echo "$TRACE_JSON" | grep -q "$TRACE_ID" || { echo "Trace $TRACE_ID not found in Jaeger"; exit 1; }
for service in api-gateway payment-service consumer-psp mock-wero mock-sct-inst event-audit-service; do
  echo "$TRACE_JSON" | grep -q "$service" || { echo "Service $service missing from trace"; exit 1; }
done

echo "==> 8. Grafana is healthy and dashboard is provisioned"
GRAFANA_HEALTH="$(curl -sS "http://${GRAFANA_HOST}/api/health")"
echo "$GRAFANA_HEALTH" | grep -qi 'ok'
DASHBOARD="$(curl -sS "http://${GRAFANA_HOST}/api/dashboards/uid/wero-v4")"
echo "$DASHBOARD" | grep -q 'MayaBanque Wero'

echo "V4 OK: correlation/paymentId -> OpenTelemetry trace -> Jaeger, Prometheus metrics -> Grafana, including outbox/Kafka audit trace continuity."
