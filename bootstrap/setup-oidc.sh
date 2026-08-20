#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKIP_ISSUER_UPDATE=false
FORCE_OVERWRITE=false
while getopts "fn" opt; do
  case "${opt}" in
    f) FORCE_OVERWRITE=true ;;
    n) SKIP_ISSUER_UPDATE=true ;;
    *) echo "Usage: $0 [-f] [-n]" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${AWS_REGION:=us-east-1}"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

echo "Checking prerequisites..."

for cmd in oc aws jq; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: ${cmd} is not installed" >&2
    exit 1
  fi
done

if ! oc whoami &>/dev/null; then
  echo "ERROR: not logged in to an OpenShift cluster (oc whoami failed)" >&2
  exit 1
fi

echo "Logged in as $(oc whoami) to $(oc whoami --show-server)"

# ---------------------------------------------------------------------------
# Step 1: Extract and upload OIDC configuration
# ---------------------------------------------------------------------------

OIDC_DIR="$(mktemp -d)"
trap 'rm -rf "${OIDC_DIR}"' EXIT

echo ""
echo "=== Step 1: OIDC configuration ==="

S3_ISSUER_URL="https://${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com/${CLUSTER_NAME}"

if ! "${FORCE_OVERWRITE}" && aws s3 ls "s3://${S3_BUCKET}/${CLUSTER_NAME}/keys.json" &>/dev/null; then
  echo "OIDC docs already present in s3://${S3_BUCKET}/${CLUSTER_NAME}/, skipping extraction."
  echo "Use -f to force overwrite."
else
  S3_BUCKET="${S3_BUCKET}" CLUSTER_NAME="${CLUSTER_NAME}" AWS_REGION="${AWS_REGION}" OUTPUT_DIR="${OIDC_DIR}" \
    "${SCRIPT_DIR}/extract-oidc-config.sh"

  echo "Uploading OIDC docs to s3://${S3_BUCKET}/${CLUSTER_NAME}/..."
  aws s3 cp "${OIDC_DIR}/.well-known/openid-configuration" \
    "s3://${S3_BUCKET}/${CLUSTER_NAME}/.well-known/openid-configuration" \
    --content-type application/json
  aws s3 cp "${OIDC_DIR}/keys.json" \
    "s3://${S3_BUCKET}/${CLUSTER_NAME}/keys.json" \
    --content-type application/json
  echo "OIDC docs uploaded."
fi

# ---------------------------------------------------------------------------
# Step 2: Verify cluster serviceAccountIssuer
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 2: Verify serviceAccountIssuer ==="

if "${SKIP_ISSUER_UPDATE}"; then
  echo "Skipping serviceAccountIssuer update (-n flag set)."
else
  CURRENT_ISSUER="$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')"
  if [[ "${CURRENT_ISSUER}" == "${S3_ISSUER_URL}" ]]; then
    echo "serviceAccountIssuer already set to ${S3_ISSUER_URL}"
  else
    echo "WARNING: Cluster serviceAccountIssuer is '${CURRENT_ISSUER}'"
    echo "         Expected: '${S3_ISSUER_URL}'"
    echo ""
    echo "The serviceAccountIssuer should be set during cluster installation"
    echo "in the install-config.yaml. Changing it on a running cluster will"
    echo "invalidate all existing ServiceAccount tokens and restart many pods."
    echo ""
    read -rp "Do you want to update it now? (y/N) " confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
      oc patch authentication cluster --type=merge \
        -p "{\"spec\":{\"serviceAccountIssuer\":\"${S3_ISSUER_URL}\"}}"
      echo "serviceAccountIssuer updated. Waiting for API server rollout..."
      oc wait co/kube-apiserver --for=condition=Progressing=True --timeout=120s || true
      oc wait co/kube-apiserver --for=condition=Progressing=False --timeout=600s
      echo "API server rollout complete."
    else
      echo "Skipping. STS-based authentication will not work until the issuer is set."
    fi
  fi
fi
