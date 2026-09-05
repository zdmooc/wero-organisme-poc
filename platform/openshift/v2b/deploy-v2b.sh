#!/usr/bin/env bash
set -euo pipefail

PROJECT=wero-poc
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

oc get project "$PROJECT" >/dev/null 2>&1 || oc new-project "$PROJECT" >/dev/null
oc project "$PROJECT" >/dev/null

echo "==> PostgreSQL"
oc apply -f "$ROOT/platform/openshift/v2/postgresql.yaml"
oc rollout status deployment/postgresql --timeout=180s

echo "==> Kafka-compatible broker (Redpanda, CRC profile)"
oc apply -f "$ROOT/platform/openshift/v2b/kafka-redpanda.yaml"
if ! oc rollout status deployment/kafka --timeout=240s; then
  echo "ERROR: Kafka broker did not become ready"
  oc get pods -l app=kafka
  oc logs deployment/kafka --tail=120 || true
  exit 1
fi

build_deploy() {
  local name="$1"
  local rel="$2"
  local mode="${3:-always}"
  local dir="$ROOT/$rel"

  if [[ "$mode" == "if-missing" ]] && oc get deployment "$name" >/dev/null 2>&1; then
    echo "==> Reusing existing $name"
    return
  fi

  echo "==> Building $name"
  (cd "$dir" && mvn clean package -DskipTests)

  if [[ ! -d "$dir/target/quarkus-app" ]]; then
    echo "ERROR: $dir/target/quarkus-app was not generated"
    exit 1
  fi

  oc get bc "$name" >/dev/null 2>&1 || oc new-build --name="$name" --binary --strategy=docker
  oc start-build "$name" --from-dir="$dir" --follow

  if ! oc get deployment "$name" >/dev/null 2>&1; then
    oc new-app --image-stream="$name:latest" --name="$name"
  else
    oc rollout restart deployment "$name"
  fi

  oc rollout status deployment/"$name" --timeout=180s
}

# V2 dependencies are reused when they already exist on the CRC cluster.
build_deploy consumer-psp services/consumer-psp if-missing
build_deploy mock-wero mocks/mock-wero if-missing
build_deploy mock-sct-inst mocks/mock-sct-inst if-missing

# V2B components are always rebuilt.
build_deploy payment-service services/payment-service always
build_deploy event-audit-service services/event-audit-service always

oc get service payment-service >/dev/null 2>&1 || oc expose deployment payment-service --port=8080
oc get route payment-service >/dev/null 2>&1 || oc expose service payment-service

oc get service event-audit-service >/dev/null 2>&1 || oc expose deployment event-audit-service --port=8080
oc get route event-audit-service >/dev/null 2>&1 || oc expose service event-audit-service

echo
echo "==> V2B resources"
oc get pods
oc get pvc
oc get svc
oc get route payment-service event-audit-service

echo
PAYMENT_ROUTE=$(oc get route payment-service -o jsonpath='{.spec.host}')
AUDIT_ROUTE=$(oc get route event-audit-service -o jsonpath='{.spec.host}')
echo "Payment API : http://$PAYMENT_ROUTE/payments/single-immediate"
echo "Outbox API  : http://$PAYMENT_ROUTE/outbox/{paymentId}"
echo "Audit API   : http://$AUDIT_ROUTE/audit/events/{paymentId}"
echo "Kafka       : kafka:9092 (cluster internal)"
