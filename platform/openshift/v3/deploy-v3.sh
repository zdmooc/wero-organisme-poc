#!/usr/bin/env bash
set -euo pipefail

PROJECT=wero-poc
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

oc get project "$PROJECT" >/dev/null 2>&1 || oc new-project "$PROJECT" >/dev/null
oc project "$PROJECT" >/dev/null

echo "==> PostgreSQL"
oc apply -f "$ROOT/platform/openshift/v2/postgresql.yaml"
oc rollout status deployment/postgresql --timeout=180s

echo "==> Kafka"
oc apply -f "$ROOT/platform/openshift/v2b/kafka-redpanda.yaml"
oc rollout status deployment/kafka --timeout=240s

echo "==> Runtime secrets"
if ! oc get secret keycloak-admin >/dev/null 2>&1; then
  oc create secret generic keycloak-admin \
    --from-literal=username=admin \
    --from-literal=password="$(openssl rand -hex 16)" >/dev/null
fi

DB_USER="$(oc get secret postgresql -o jsonpath='{.data.database-user}' | base64 -d)"
DB_PASSWORD="$(oc get secret postgresql -o jsonpath='{.data.database-password}' | base64 -d)"
DB_NAME="$(oc get secret postgresql -o jsonpath='{.data.database-name}' | base64 -d)"

if ! oc get secret wero-v3-app >/dev/null 2>&1; then
  SCA_HEX="$(openssl rand -hex 3)"
  SCA_CODE="$(printf '%06d' $((16#$SCA_HEX % 1000000)))"
  oc create secret generic wero-v3-app \
    --from-literal=DB_USER="$DB_USER" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --from-literal=DB_NAME="$DB_NAME" \
    --from-literal=SCA_DEMO_CODE="$SCA_CODE" >/dev/null
fi

if ! oc get secret wero-v3-demo-users >/dev/null 2>&1; then
  oc create secret generic wero-v3-demo-users \
    --from-literal=ALICE_PASSWORD="$(openssl rand -hex 10)" \
    --from-literal=AUDITOR_PASSWORD="$(openssl rand -hex 10)" >/dev/null
fi

echo "==> Keycloak realm"
oc create configmap keycloak-realm \
  --from-file=mayabanque-realm.json="$ROOT/platform/openshift/v3/mayabanque-realm.json" \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f "$ROOT/platform/openshift/v3/keycloak.yaml"
oc rollout status deployment/keycloak --timeout=360s
oc get route keycloak >/dev/null 2>&1 || oc expose service keycloak

KC_ADMIN_USER="$(oc get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)"
KC_ADMIN_PASSWORD="$(oc get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)"
ALICE_PASSWORD="$(oc get secret wero-v3-demo-users -o jsonpath='{.data.ALICE_PASSWORD}' | base64 -d)"
AUDITOR_PASSWORD="$(oc get secret wero-v3-demo-users -o jsonpath='{.data.AUDITOR_PASSWORD}' | base64 -d)"
KEYCLOAK_POD="$(oc get pods -l app=keycloak -o jsonpath='{.items[0].metadata.name}')"

oc exec "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD" >/dev/null
oc exec "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh set-password \
  -r mayabanque --username alice --new-password "$ALICE_PASSWORD" >/dev/null
oc exec "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh set-password \
  -r mayabanque --username auditor --new-password "$AUDITOR_PASSWORD" >/dev/null

echo "==> Keycloak demo identities configured"

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
  fi

  if [[ "$name" == "payment-service" || "$name" == "event-audit-service" ]]; then
    oc set env deployment/"$name" --from=secret/wero-v3-app >/dev/null
  fi

  oc rollout restart deployment/"$name" >/dev/null
  oc rollout status deployment/"$name" --timeout=240s
}

build_deploy consumer-psp services/consumer-psp if-missing
build_deploy mock-wero mocks/mock-wero if-missing
build_deploy mock-sct-inst mocks/mock-sct-inst if-missing
build_deploy payment-service services/payment-service always
build_deploy event-audit-service services/event-audit-service always

oc get service payment-service >/dev/null 2>&1 || oc expose deployment payment-service --port=8080
oc get route payment-service >/dev/null 2>&1 || oc expose service payment-service
oc get service event-audit-service >/dev/null 2>&1 || oc expose deployment event-audit-service --port=8080
oc get route event-audit-service >/dev/null 2>&1 || oc expose service event-audit-service

echo
echo "==> V3 resources"
oc get pods
oc get svc
oc get route keycloak payment-service event-audit-service

echo
KC_ROUTE="$(oc get route keycloak -o jsonpath='{.spec.host}')"
PAYMENT_ROUTE="$(oc get route payment-service -o jsonpath='{.spec.host}')"
AUDIT_ROUTE="$(oc get route event-audit-service -o jsonpath='{.spec.host}')"
echo "Keycloak     : http://$KC_ROUTE"
echo "Token API    : http://$KC_ROUTE/realms/mayabanque/protocol/openid-connect/token"
echo "Consent API  : http://$PAYMENT_ROUTE/consents"
echo "Payment API  : http://$PAYMENT_ROUTE/payments/single-immediate"
echo "Audit API    : http://$AUDIT_ROUTE/audit/events/{paymentId}"
echo "Demo credentials and SCA code are stored only in OpenShift Secrets."
