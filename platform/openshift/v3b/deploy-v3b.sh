#!/usr/bin/env bash
set -euo pipefail

PROJECT=wero-poc
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

oc get project "$PROJECT" >/dev/null 2>&1 || oc new-project "$PROJECT" >/dev/null
oc project "$PROJECT" >/dev/null

# Rebuild and validate the V3A security foundation first.
"$ROOT/platform/openshift/v3/deploy-v3.sh"

build_deploy() {
  local name="$1"
  local rel="$2"
  local dir="$ROOT/$rel"

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
    oc rollout restart deployment/"$name" >/dev/null
  fi

  oc rollout status deployment/"$name" --timeout=240s
}

echo "==> API Gateway"
build_deploy api-gateway services/api-gateway

# Ensure the labels referenced by the NetworkPolicy are present on pod templates.
oc patch deployment api-gateway -p '{"spec":{"template":{"metadata":{"labels":{"app":"api-gateway"}}}}}' >/dev/null
oc patch deployment payment-service -p '{"spec":{"template":{"metadata":{"labels":{"app":"payment-service"}}}}}' >/dev/null
oc patch deployment event-audit-service -p '{"spec":{"template":{"metadata":{"labels":{"app":"event-audit-service"}}}}}' >/dev/null

oc rollout status deployment/api-gateway --timeout=240s
oc rollout status deployment/payment-service --timeout=240s
oc rollout status deployment/event-audit-service --timeout=240s

oc get service api-gateway >/dev/null 2>&1 || oc expose deployment api-gateway --port=8080
oc get route api-gateway >/dev/null 2>&1 || oc expose service api-gateway

# Backends remain ClusterIP-only. Only Keycloak and the API Gateway keep public Routes.
oc delete route payment-service --ignore-not-found
oc delete route event-audit-service --ignore-not-found

# Defense in depth: even from another pod in the namespace, HTTP backends accept
# ingress only from pods carrying app=api-gateway.
oc apply -f "$ROOT/platform/openshift/v3b/network-policy.yaml"

echo
echo "==> V3B resources"
oc get pods
oc get svc api-gateway payment-service event-audit-service keycloak
oc get route api-gateway keycloak
oc get networkpolicy gateway-only-payment gateway-only-audit

echo
GATEWAY_ROUTE="$(oc get route api-gateway -o jsonpath='{.spec.host}')"
KC_ROUTE="$(oc get route keycloak -o jsonpath='{.spec.host}')"
echo "Keycloak     : http://$KC_ROUTE"
echo "API Gateway  : http://$GATEWAY_ROUTE"
echo "Consent API  : http://$GATEWAY_ROUTE/api/consents"
echo "Payment API  : http://$GATEWAY_ROUTE/api/payments/single-immediate"
echo "Audit API    : http://$GATEWAY_ROUTE/api/audit/events/{paymentId}"
echo "Direct payment-service and event-audit-service Routes are intentionally absent."
