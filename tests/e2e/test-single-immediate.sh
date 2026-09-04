#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-$(oc get route payment-service -n wero-poc -o jsonpath='{.spec.host}')}"

curl -sS -X POST "http://${HOST}/payments/single-immediate" \
  -H 'Content-Type: application/json' \
  -d '{
    "paymentId":"PAY-000001",
    "amountCents":1250,
    "currency":"EUR",
    "debtorAlias":"+33600000001",
    "creditorAlias":"+33600000002"
  }'

echo
