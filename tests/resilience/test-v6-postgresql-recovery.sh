#!/usr/bin/env bash
set -euo pipefail

PROJECT="wero-poc"
GITOPS_NS="openshift-gitops"
APP="wero-poc-crc"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pg_scalar() {
  local sql="$1"
  oc exec -n "$PROJECT" deployment/postgresql -- sh -lc \
    "psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -Atc \"$sql\"" \
    2>/dev/null | tr -d '\r'
}

echo "==> 1. Preconditions: V6 GitOps state and single-replica PostgreSQL with bound PVC"
SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}')"
HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}')"
[[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] || {
  echo "Argo CD must be Synced/Healthy before PostgreSQL chaos (sync=$SYNC health=$HEALTH)"
  exit 1
}

[[ "$(oc get deployment postgresql -n "$PROJECT" -o jsonpath='{.spec.replicas}')" == "1" ]] || {
  echo "PostgreSQL must remain a single-replica SPOF for this recovery test"
  exit 1
}

PVC_PHASE="$(oc get pvc postgresql-data -n "$PROJECT" -o jsonpath='{.status.phase}')"
[[ "$PVC_PHASE" == "Bound" ]] || { echo "postgresql-data PVC is not Bound"; exit 1; }
PVC_UID_BEFORE="$(oc get pvc postgresql-data -n "$PROJECT" -o jsonpath='{.metadata.uid}')"

echo "==> 2. Create committed business evidence with the full V5 regression"
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

PAYMENT_ID="$(pg_scalar "select payment_id from payments where status='SETTLED' order by updated_at desc limit 1;")"
[[ -n "$PAYMENT_ID" ]] || { echo "No SETTLED payment found before PostgreSQL failure"; exit 1; }

PAYMENT_STATUS_BEFORE="$(pg_scalar "select status from payments where payment_id='${PAYMENT_ID}';")"
LEDGER_COUNT_BEFORE="$(pg_scalar "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}';")"
OUTBOX_COUNT_BEFORE="$(pg_scalar "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}';")"

[[ "$PAYMENT_STATUS_BEFORE" == "SETTLED" ]] || { echo "Pre-failure payment is not SETTLED"; exit 1; }
[[ "${LEDGER_COUNT_BEFORE:-0}" -ge 1 ]] || { echo "Pre-failure ledger evidence is missing"; exit 1; }
[[ "${OUTBOX_COUNT_BEFORE:-0}" -ge 1 ]] || { echo "Pre-failure outbox evidence is missing"; exit 1; }

echo "evidence paymentId=$PAYMENT_ID status=$PAYMENT_STATUS_BEFORE ledger=$LEDGER_COUNT_BEFORE outbox=$OUTBOX_COUNT_BEFORE"

echo "==> 3. Delete the PostgreSQL pod and measure recovery"
OLD_POD="$(oc get pods -n "$PROJECT" -l app=postgresql --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$OLD_POD" ]] || { echo "No running PostgreSQL pod found"; exit 1; }

START_EPOCH="$(date +%s)"
oc delete pod "$OLD_POD" -n "$PROJECT" --wait=false >/dev/null

RECOVERED=false
NEW_POD=""
for _ in $(seq 1 120); do
  NEW_POD="$(oc get pods -n "$PROJECT" -l app=postgresql --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  READY=""
  if [[ -n "$NEW_POD" ]]; then
    READY="$(oc get pod "$NEW_POD" -n "$PROJECT" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  fi
  DB_OK="$(pg_scalar "select 1;" 2>/dev/null || true)"
  if [[ -n "$NEW_POD" && "$NEW_POD" != "$OLD_POD" && "$READY" == "True" && "$DB_OK" == "1" ]]; then
    RECOVERED=true
    break
  fi
  sleep 2
done

[[ "$RECOVERED" == "true" ]] || {
  echo "PostgreSQL did not recover within the test window"
  oc get pods -n "$PROJECT" -l app=postgresql -o wide
  exit 1
}

RTO_SECONDS="$(( $(date +%s) - START_EPOCH ))"
echo "PostgreSQL recovered as pod/$NEW_POD in ${RTO_SECONDS}s"

echo "==> 4. Verify PVC identity and committed data survived"
PVC_UID_AFTER="$(oc get pvc postgresql-data -n "$PROJECT" -o jsonpath='{.metadata.uid}')"
[[ "$PVC_UID_AFTER" == "$PVC_UID_BEFORE" ]] || {
  echo "postgresql-data PVC identity changed unexpectedly"
  exit 1
}

PAYMENT_STATUS_AFTER="$(pg_scalar "select status from payments where payment_id='${PAYMENT_ID}';")"
LEDGER_COUNT_AFTER="$(pg_scalar "select count(*) from ledger_entries where payment_id='${PAYMENT_ID}';")"
OUTBOX_COUNT_AFTER="$(pg_scalar "select count(*) from outbox_events where aggregate_id='${PAYMENT_ID}';")"

[[ "$PAYMENT_STATUS_AFTER" == "$PAYMENT_STATUS_BEFORE" ]] || {
  echo "Payment status changed across PostgreSQL restart: before=$PAYMENT_STATUS_BEFORE after=$PAYMENT_STATUS_AFTER"
  exit 1
}
[[ "$LEDGER_COUNT_AFTER" == "$LEDGER_COUNT_BEFORE" ]] || {
  echo "Ledger row count changed across PostgreSQL restart: before=$LEDGER_COUNT_BEFORE after=$LEDGER_COUNT_AFTER"
  exit 1
}
[[ "$OUTBOX_COUNT_AFTER" == "$OUTBOX_COUNT_BEFORE" ]] || {
  echo "Outbox row count changed across PostgreSQL restart: before=$OUTBOX_COUNT_BEFORE after=$OUTBOX_COUNT_AFTER"
  exit 1
}

echo "committed evidence preserved: payment=$PAYMENT_STATUS_AFTER ledger=$LEDGER_COUNT_AFTER outbox=$OUTBOX_COUNT_AFTER"

echo "==> 5. Wait for GitOps/application health after database recovery"
ARGO_READY=false
for _ in $(seq 1 60); do
  SYNC="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH="$(oc get application "$APP" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    ARGO_READY=true
    break
  fi
  sleep 5
done
[[ "$ARGO_READY" == "true" ]] || { echo "Argo CD did not return to Synced/Healthy"; exit 1; }

echo "==> 6. New business transaction succeeds after recovery"
EXPECTED_GATEWAY_REPLICAS=2 "$ROOT/tests/e2e/test-v5-gitops.sh"

echo "V6 OK (phase B1): PostgreSQL single-pod failure recovered in ${RTO_SECONDS}s using the same PVC; the selected committed payment/ledger/outbox evidence lost 0 rows, and a new V5 business/observability regression succeeded. This is CRC recovery evidence, not a PostgreSQL HA or production RPO=0 claim."
