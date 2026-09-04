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
  (cd "$dir" && mvn -q clean package -DskipTests)

  oc get bc "$name" >/dev/null 2>&1 || oc new-build --name="$name" --binary --strategy=docker
  oc start-build "$name" --from-dir="$dir" --follow

  if ! oc get deployment "$name" >/dev/null 2>&1; then
    oc new-app --image-stream="$name:latest" --name="$name"
    oc expose service "$name" >/dev/null
  else
    oc rollout restart deployment "$name"
  fi

done

# Only payment-service is externally exposed.
oc get route payment-service >/dev/null 2>&1 || oc expose service payment-service

echo
oc get pods

echo
ROUTE=$(oc get route payment-service -o jsonpath='{.spec.host}')
echo "Payment API: http://$ROUTE/payments/single-immediate"
