#!/usr/bin/env bash
set -euo pipefail

PROJECT=wero-poc
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

oc get project "$PROJECT" >/dev/null 2>&1 || oc new-project "$PROJECT" >/dev/null
oc project "$PROJECT" >/dev/null

echo "==> Deploying PostgreSQL"
oc apply -f "$ROOT/platform/openshift/v2/postgresql.yaml"
oc rollout status deployment/postgresql --timeout=180s

components=(
  "payment-service:services/payment-service"
  "consumer-psp:services/consumer-psp"
  "mock-wero:mocks/mock-wero"
  "mock-sct-inst:mocks/mock-sct-inst"
)

for item in "${components[@]}"; do
  name="${item%%:*}"
  rel="${item#*:}"
  dir="$ROOT/$rel"

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

done

oc get service payment-service >/dev/null 2>&1 || oc expose deployment payment-service --port=8080
oc get route payment-service >/dev/null 2>&1 || oc expose service payment-service

echo
echo "==> V2 resources"
oc get pods
oc get pvc
oc get svc
oc get route payment-service

echo
ROUTE=$(oc get route payment-service -o jsonpath='{.spec.host}')
echo "Payment API: http://$ROUTE/payments/single-immediate"
echo "Status API : http://$ROUTE/payments/{paymentId}"
echo "Reconcile  : POST http://$ROUTE/payments/{paymentId}/reconcile"
