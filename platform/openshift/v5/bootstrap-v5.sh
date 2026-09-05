#!/usr/bin/env bash
set -euo pipefail

PROJECT="wero-poc"
GITOPS_NS="openshift-gitops"
APP_NAME="wero-poc-crc"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REBUILD_IMAGES="${REBUILD_IMAGES:-false}"

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc is required"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "ERROR: login to OpenShift first"; exit 1; }

oc get project "$PROJECT" >/dev/null 2>&1 || oc new-project "$PROJECT" >/dev/null
oc project "$PROJECT" >/dev/null

# Secrets are deliberately external to Git. Existing V3/V4 secrets are reused.
if ! oc get secret postgresql >/dev/null 2>&1; then
  oc create secret generic postgresql \
    --from-literal=database-user=mayabanque \
    --from-literal=database-password="$(openssl rand -hex 16)" \
    --from-literal=database-name=wero >/dev/null
fi

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

build_image() {
  local name="$1"
  local rel="$2"
  local dir="$ROOT/$rel"
  local current=""
  current="$(oc get istag "$name:latest" -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)"

  if [[ "$REBUILD_IMAGES" != "true" && -n "$current" ]]; then
    echo "==> Reusing image $name:latest"
    return
  fi

  echo "==> Building image $name"
  (cd "$dir" && mvn clean package -DskipTests)
  [[ -d "$dir/target/quarkus-app" ]] || { echo "ERROR: $dir/target/quarkus-app missing"; exit 1; }
  oc get bc "$name" >/dev/null 2>&1 || oc new-build --name="$name" --binary --strategy=docker >/dev/null
  oc start-build "$name" --from-dir="$dir" --follow
}

# Build plane stays separate from the deployment plane. Argo CD owns runtime state.
build_image api-gateway services/api-gateway
build_image payment-service services/payment-service
build_image consumer-psp services/consumer-psp
build_image event-audit-service services/event-audit-service
build_image mock-wero mocks/mock-wero
build_image mock-sct-inst mocks/mock-sct-inst

# Migration hygiene from imperative V3/V4 deployments.
oc delete route payment-service event-audit-service --ignore-not-found >/dev/null 2>&1 || true
for d in api-gateway payment-service consumer-psp event-audit-service mock-wero mock-sct-inst; do
  oc annotate deployment "$d" image.openshift.io/triggers- >/dev/null 2>&1 || true
done

# Install Red Hat OpenShift GitOps (Argo CD) through OLM if needed.
if ! oc get subscription openshift-gitops-operator -n openshift-operators >/dev/null 2>&1; then
  echo "==> Discovering OpenShift GitOps operator channel"
  CHANNEL=""
  SOURCE=""
  SOURCE_NS=""
  for _ in $(seq 1 60); do
    CHANNEL="$(oc get packagemanifest openshift-gitops-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)"
    SOURCE="$(oc get packagemanifest openshift-gitops-operator -n openshift-marketplace -o jsonpath='{.status.catalogSource}' 2>/dev/null || true)"
    SOURCE_NS="$(oc get packagemanifest openshift-gitops-operator -n openshift-marketplace -o jsonpath='{.status.catalogSourceNamespace}' 2>/dev/null || true)"
    [[ -n "$CHANNEL" && -n "$SOURCE" && -n "$SOURCE_NS" ]] && break
    sleep 5
  done
  [[ -n "$CHANNEL" && -n "$SOURCE" && -n "$SOURCE_NS" ]] || {
    echo "ERROR: OpenShift GitOps package manifest not available from OperatorHub"
    exit 1
  }

  echo "==> Installing OpenShift GitOps operator channel=$CHANNEL source=$SOURCE"
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: ${SOURCE}
  sourceNamespace: ${SOURCE_NS}
EOF
else
  echo "==> Reusing OpenShift GitOps operator subscription"
fi

echo "==> Waiting for Argo CD CRDs"
for _ in $(seq 1 180); do
  oc get crd applications.argoproj.io >/dev/null 2>&1 && break
  sleep 5
done
oc get crd applications.argoproj.io >/dev/null 2>&1 || { echo "ERROR: Argo CD Application CRD not ready"; exit 1; }

# The operator normally creates the default openshift-gitops instance.
for _ in $(seq 1 180); do
  oc get namespace "$GITOPS_NS" >/dev/null 2>&1 && break
  sleep 5
done
oc get namespace "$GITOPS_NS" >/dev/null 2>&1 || { echo "ERROR: $GITOPS_NS namespace not created"; exit 1; }

# If the operator was configured without a default instance, create the lab instance explicitly.
if ! oc get argocd openshift-gitops -n "$GITOPS_NS" >/dev/null 2>&1; then
  echo "==> Creating OpenShift GitOps ArgoCD instance"
  cat <<'EOF' | oc apply -f -
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: openshift-gitops
  namespace: openshift-gitops
spec:
  server:
    route:
      enabled: true
EOF
fi

echo "==> Waiting for Argo CD server"
for _ in $(seq 1 180); do
  oc get deployment openshift-gitops-server -n "$GITOPS_NS" >/dev/null 2>&1 && break
  sleep 5
done
oc rollout status deployment/openshift-gitops-server -n "$GITOPS_NS" --timeout=600s

# Grant the OpenShift GitOps instance management of the application namespace.
oc label namespace "$PROJECT" argocd.argoproj.io/managed-by="$GITOPS_NS" --overwrite >/dev/null

# AppProject + Application are the only imperative hand-off to the GitOps control plane.
echo "==> Registering Wero GitOps project and application"
oc apply -f "$ROOT/gitops/argocd/project.yaml"
oc apply -f "$ROOT/gitops/argocd/application.yaml"
oc annotate application "$APP_NAME" -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite >/dev/null

wait_application() {
  local timeout_seconds=600
  local waited=0
  while (( waited < timeout_seconds )); do
    local sync health
    sync="$(oc get application "$APP_NAME" -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(oc get application "$APP_NAME" -n "$GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    printf '\rArgo CD: sync=%-10s health=%-12s waited=%ss' "${sync:-Unknown}" "${health:-Unknown}" "$waited"
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      echo
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo
  oc get application "$APP_NAME" -n "$GITOPS_NS" -o yaml | tail -n 120
  echo "ERROR: Argo CD application did not reach Synced/Healthy"
  return 1
}

wait_application

echo "==> Waiting for Git-managed workloads"
for d in postgresql kafka keycloak jaeger prometheus grafana api-gateway payment-service consumer-psp event-audit-service mock-wero mock-sct-inst; do
  oc rollout status deployment/"$d" -n "$PROJECT" --timeout=360s
done

# Configure demo passwords after the Git-managed Keycloak realm is live.
KC_ADMIN_USER="$(oc get secret keycloak-admin -n "$PROJECT" -o jsonpath='{.data.username}' | base64 -d)"
KC_ADMIN_PASSWORD="$(oc get secret keycloak-admin -n "$PROJECT" -o jsonpath='{.data.password}' | base64 -d)"
ALICE_PASSWORD="$(oc get secret wero-v3-demo-users -n "$PROJECT" -o jsonpath='{.data.ALICE_PASSWORD}' | base64 -d)"
AUDITOR_PASSWORD="$(oc get secret wero-v3-demo-users -n "$PROJECT" -o jsonpath='{.data.AUDITOR_PASSWORD}' | base64 -d)"
KEYCLOAK_POD="$(oc get pods -n "$PROJECT" -l app=keycloak --field-selector=status.phase=Running --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)"
[[ -n "$KEYCLOAK_POD" ]] || { echo "ERROR: Keycloak pod not found"; exit 1; }
KEYCLOAK_POD_IP="$(oc get pod "$KEYCLOAK_POD" -n "$PROJECT" -o jsonpath='{.status.podIP}')"
KCADM_SERVER="http://${KEYCLOAK_POD_IP}:8080"
MSYS_NO_PATHCONV=1 oc exec -n "$PROJECT" "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server "$KCADM_SERVER" --realm master --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD" >/dev/null
MSYS_NO_PATHCONV=1 oc exec -n "$PROJECT" "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh set-password \
  -r mayabanque --username alice --new-password "$ALICE_PASSWORD" >/dev/null
MSYS_NO_PATHCONV=1 oc exec -n "$PROJECT" "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh set-password \
  -r mayabanque --username auditor --new-password "$AUDITOR_PASSWORD" >/dev/null
unset KC_ADMIN_PASSWORD ALICE_PASSWORD AUDITOR_PASSWORD DB_PASSWORD

echo
echo "==> V5 GitOps status"
oc get application "$APP_NAME" -n "$GITOPS_NS"
oc get pods -n "$PROJECT"
oc get route api-gateway keycloak jaeger prometheus grafana -n "$PROJECT"
oc get networkpolicy gateway-only-payment gateway-only-audit -n "$PROJECT"

echo
ARGO_ROUTE="$(oc get route openshift-gitops-server -n "$GITOPS_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "$ARGO_ROUTE" ]] && echo "Argo CD     : https://$ARGO_ROUTE"
echo "Application : $APP_NAME (automated sync + prune + selfHeal)"
echo "Desired Git : v5-gitops-argocd / gitops/overlays/crc"
echo "Secrets     : external to Git"
echo "Backend Routes payment-service/event-audit-service remain absent."
