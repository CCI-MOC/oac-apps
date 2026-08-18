#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${AWS_REGION:=us-east-1}"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

echo "Checking prerequisites..."

for cmd in oc aws jq helm; do
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

if aws s3 ls "s3://${S3_BUCKET}/${CLUSTER_NAME}/keys.json" &>/dev/null; then
  echo "OIDC docs already present in s3://${S3_BUCKET}/${CLUSTER_NAME}/, skipping extraction."
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

# ---------------------------------------------------------------------------
# Step 3: Install OpenShift GitOps operator
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: OpenShift GitOps operator ==="

echo "Installing OpenShift GitOps operator..."
helm template openshift-gitops "${REPO_ROOT}/charts/openshift-gitops" \
  --show-only templates/subscription.yaml \
  | oc apply -f -

echo "Waiting for operator to become available..."
until oc get deployment openshift-gitops-server -n openshift-gitops &>/dev/null; do
  echo "  waiting for openshift-gitops-server deployment..."
  sleep 10
done
oc wait deployment/openshift-gitops-server -n openshift-gitops \
  --for=condition=Available --timeout=300s
echo "OpenShift GitOps operator is ready."

# ---------------------------------------------------------------------------
# Step 4: Configure ArgoCD instance
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 4: ArgoCD instance ==="

echo "Applying ArgoCD configuration..."
helm template openshift-gitops "${REPO_ROOT}/charts/openshift-gitops" \
  | oc apply -f -

echo "Waiting for ArgoCD to reconcile..."
oc wait argocd/openshift-gitops -n openshift-gitops \
  --for=jsonpath='{.status.phase}'=Available --timeout=300s
echo "ArgoCD is ready."

## ---------------------------------------------------------------------------
## Step 5: Apply hub ApplicationSet
## ---------------------------------------------------------------------------
#
#echo ""
#echo "=== Step 5: Hub ApplicationSet ==="
#
#echo "Applying hub ApplicationSet..."
#oc apply -f "${REPO_ROOT}/applicationsets/hub-components.yaml"
#
#echo ""
#echo "Hub bootstrap complete. ArgoCD will now manage hub cluster components."
#echo "Once ACM is running, apply the managed cluster resources:"
#echo ""
#echo "  oc apply -f ${REPO_ROOT}/placements/"
#echo "  oc apply -f ${REPO_ROOT}/applicationsets/managed-components.yaml"
#echo ""
#echo "Access the ArgoCD console:"
#echo "  $(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo '(route not yet available)')"
