#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-$(oc get route payment-service -n wero-poc -o jsonpath='{.spec.host}')}"
BASE="http://${HOST}"

echo "==> 1. Normal settled payment"
curl -sS -X POST "$BASE/payments/single-immediate" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: idem-v2-settled-001' \
  -d '{
    "paymentId":"PAY-V2-SETTLED-001",
    "amountCents":2500,
    "currency":"EUR",
    "debtorAlias":"+33610000001",
    "creditorAlias":"+33610000002"
  }'
echo

echo "==> 2. Replay with the same idempotency key: no second payment must be created"
curl -sS -i -X POST "$BASE/payments/single-immediate" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: idem-v2-settled-001' \
  -d '{
    "paymentId":"PAY-V2-SETTLED-001",
    "amountCents":2500,
    "currency":"EUR",
    "debtorAlias":"+33610000001",
    "creditorAlias":"+33610000002"
  }' | sed -n '1,15p'
echo

echo "==> 3. Simulate: SCT Inst commits but response is lost"
curl -sS -i -X POST "$BASE/payments/single-immediate" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: idem-v2-unknown-001' \
  -d '{
    "paymentId":"PAY-V2-UNKNOWN-001",
    "amountCents":9900,
    "currency":"EUR",
    "debtorAlias":"+33620000001",
    "creditorAlias":"+33620000002",
    "simulateMode":"TIMEOUT_AFTER_SETTLEMENT"
  }' | sed -n '1,20p'
echo

echo "==> 4. Local state must be UNKNOWN"
curl -sS "$BASE/payments/PAY-V2-UNKNOWN-001"
echo

echo "==> 5. Reconcile by querying SCT Inst status - no payment replay"
curl -sS -X POST "$BASE/payments/PAY-V2-UNKNOWN-001/reconcile"
echo

echo "==> 6. Final local state"
curl -sS "$BASE/payments/PAY-V2-UNKNOWN-001"
echo

echo "==> 7. Ledger entry created once after reconciliation"
curl -sS "$BASE/payments/PAY-V2-UNKNOWN-001/ledger"
echo
