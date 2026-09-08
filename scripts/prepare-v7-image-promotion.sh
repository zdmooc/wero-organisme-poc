#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:-}"
case "${ENVIRONMENT}" in
  preprod|prod) ;;
  *) echo "Usage: $0 preprod|prod"; exit 2 ;;
esac

KUSTOMIZE_BIN="${KUSTOMIZE_BIN:-kustomize}"
command -v "${KUSTOMIZE_BIN}" >/dev/null 2>&1 || { echo "ERROR: kustomize is required"; exit 1; }

OVERLAY="gitops/overlays/${ENVIRONMENT}-c5"
[[ -f "${OVERLAY}/kustomization.yaml" ]] || { echo "ERROR: missing ${OVERLAY}/kustomization.yaml"; exit 1; }

vars=(
  API_GATEWAY_IMAGE
  PAYMENT_SERVICE_IMAGE
  CONSUMER_PSP_IMAGE
  EVENT_AUDIT_SERVICE_IMAGE
  MOCK_WERO_IMAGE
  MOCK_SCT_INST_IMAGE
)

for var in "${vars[@]}"; do
  value="${!var:-}"
  [[ -n "${value}" ]] || { echo "ERROR: ${var} is required"; exit 2; }
  [[ "${value}" =~ ^[^[:space:]]+@sha256:[0-9a-fA-F]{64}$ ]] || {
    echo "ERROR: ${var} must be an immutable image@sha256:<64hex> reference"
    exit 2
  }
done

pushd "${OVERLAY}" >/dev/null
"${KUSTOMIZE_BIN}" edit set image \
  "image-registry.openshift-image-registry.svc:5000/wero-poc/api-gateway=${API_GATEWAY_IMAGE}" \
  "image-registry.openshift-image-registry.svc:5000/wero-poc/payment-service=${PAYMENT_SERVICE_IMAGE}" \
  "image-registry.openshift-image-registry.svc:5000/wero-poc/consumer-psp=${CONSUMER_PSP_IMAGE}" \
  "image-registry.openshift-image-registry.svc:5000/wero-poc/event-audit-service=${EVENT_AUDIT_SERVICE_IMAGE}" \
  "image-registry.openshift-image-registry.svc:5000/wero-poc/mock-wero=${MOCK_WERO_IMAGE}" \
  "image-registry.openshift-image-registry.svc:5000/wero-poc/mock-sct-inst=${MOCK_SCT_INST_IMAGE}"
popd >/dev/null

render="$(mktemp)"
trap 'rm -f "${render}"' EXIT
"${KUSTOMIZE_BIN}" build "${OVERLAY}" > "${render}"

for app in api-gateway payment-service consumer-psp event-audit-service mock-wero mock-sct-inst; do
  if grep -qF "image-registry.openshift-image-registry.svc:5000/wero-poc/${app}:latest" "${render}"; then
    echo "ERROR: mutable application image remains in rendered target: ${app}:latest"
    exit 1
  fi
done

DIGEST_COUNT="$(grep -Ec '^[[:space:]]*image: .*@sha256:[0-9a-fA-F]{64}[[:space:]]*$' "${render}" || true)"
[[ "${DIGEST_COUNT}" -ge 6 ]] || { echo "ERROR: expected at least six digest-pinned rendered application images"; exit 1; }

echo "V7 immutable promotion prepared for ${ENVIRONMENT}. Review and commit the kustomization diff; this script does not commit or deploy."
