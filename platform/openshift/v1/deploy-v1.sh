#!/usr/bin/env bash
set -euo pipefail

PROJECT=wero-poc
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

oc new-project "$PROJECT" >/dev/null 2>&1 || oc project "$PROJECT" >/dev/null

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

# Only payment-service is externally exposed.
oc get route payment-service >/dev/null 2>&1 || oc expose service payment-service

echo
oc get pods

echo
oc get svc

echo
oc get route

echo
ROUTE=$(oc get route payment-service -o jsonpath='{.spec.host}')
echo "Payment API: http://$ROUTE/payments/single-immediate"
