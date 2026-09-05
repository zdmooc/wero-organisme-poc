#!/usr/bin/env bash
set -euo pipefail

PROJECT=wero-poc
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

oc get project "$PROJECT" >/dev/null 2>&1 || oc new-project "$PROJECT" >/dev/null
oc project "$PROJECT" >/dev/null

# V4 is an overlay on the already validated V3B security architecture.
"$ROOT/platform/openshift/v3b/deploy-v3b.sh"

echo "==> Jaeger"
oc apply -f "$ROOT/platform/openshift/v4/jaeger.yaml"
oc rollout status deployment/jaeger --timeout=300s

echo "==> Prometheus"
oc apply -f "$ROOT/platform/openshift/v4/prometheus.yaml"
oc rollout status deployment/prometheus --timeout=300s

echo "==> Grafana"
oc apply -f "$ROOT/platform/openshift/v4/grafana.yaml"
oc rollout status deployment/grafana --timeout=300s

build_deploy() {
  local name="$1"
  local rel="$2"
  local dir="$ROOT/$rel"

  echo "==> Building observable $name"
  (cd "$dir" && mvn clean package -DskipTests)
  [[ -d "$dir/target/quarkus-app" ]] || { echo "ERROR: $dir/target/quarkus-app missing"; exit 1; }

  oc get bc "$name" >/dev/null 2>&1 || oc new-build --name="$name" --binary --strategy=docker
  oc start-build "$name" --from-dir="$dir" --follow

  if ! oc get deployment "$name" >/dev/null 2>&1; then
    oc new-app --image-stream="$name:latest" --name="$name"
  fi
  oc rollout restart deployment/"$name" >/dev/null
  oc rollout status deployment/"$name" --timeout=300s
}

# deploy-v3b already rebuilt gateway/payment/audit from this V4 branch.
# These three services were reused by older scripts and must be rebuilt for OTel instrumentation.
build_deploy consumer-psp services/consumer-psp
build_deploy mock-wero mocks/mock-wero
build_deploy mock-sct-inst mocks/mock-sct-inst

# Restart the V4 services once Jaeger is available so exporters reconnect immediately.
oc rollout restart deployment/api-gateway deployment/payment-service deployment/event-audit-service >/dev/null
oc rollout status deployment/api-gateway --timeout=300s
oc rollout status deployment/payment-service --timeout=300s
oc rollout status deployment/event-audit-service --timeout=300s

# Preserve V3B backend isolation, while allowing Prometheus to scrape /q/metrics.
oc apply -f "$ROOT/platform/openshift/v4/network-policy-observability.yaml"
oc delete route payment-service event-audit-service --ignore-not-found >/dev/null

oc get route jaeger >/dev/null 2>&1 || oc expose service jaeger --port=ui
oc get route prometheus >/dev/null 2>&1 || oc expose service prometheus --port=web
oc get route grafana >/dev/null 2>&1 || oc expose service grafana --port=http

echo
echo "==> V4 observability resources"
oc get pods
oc get svc jaeger prometheus grafana api-gateway payment-service event-audit-service
oc get route api-gateway keycloak jaeger prometheus grafana
oc get networkpolicy gateway-only-payment gateway-only-audit

echo
GATEWAY_ROUTE="$(oc get route api-gateway -o jsonpath='{.spec.host}')"
JAEGER_ROUTE="$(oc get route jaeger -o jsonpath='{.spec.host}')"
PROM_ROUTE="$(oc get route prometheus -o jsonpath='{.spec.host}')"
GRAFANA_ROUTE="$(oc get route grafana -o jsonpath='{.spec.host}')"
echo "API Gateway : http://$GATEWAY_ROUTE"
echo "Jaeger      : http://$JAEGER_ROUTE"
echo "Prometheus  : http://$PROM_ROUTE"
echo "Grafana     : http://$GRAFANA_ROUTE"
echo "Backend business Routes remain absent."
