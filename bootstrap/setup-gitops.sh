#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

echo "Checking prerequisites..."

for cmd in oc helm; do
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
# Step 1: Install OpenShift GitOps operator
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 1: OpenShift GitOps operator ==="

echo "Installing OpenShift GitOps operator..."
helm template openshift-gitops "${REPO_ROOT}/charts/openshift-gitops" \
  --show-only templates/subscription.yaml |
  oc apply -f -

echo "Waiting for operator to become available..."
until oc get deployment openshift-gitops-server -n openshift-gitops &>/dev/null; do
  echo "  waiting for openshift-gitops-server deployment..."
  sleep 10
done
oc wait deployment/openshift-gitops-server -n openshift-gitops \
  --for=condition=Available --timeout=300s
echo "OpenShift GitOps operator is ready."

# ---------------------------------------------------------------------------
# Step 2: Configure ArgoCD instance
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 2: ArgoCD instance ==="

echo "Applying ArgoCD configuration..."
helm template openshift-gitops "${REPO_ROOT}/charts/openshift-gitops" |
  oc apply -f -

echo "Waiting for ArgoCD to reconcile..."
oc wait argocd/openshift-gitops -n openshift-gitops \
  --for=jsonpath='{.status.phase}'=Available --timeout=300s
echo "ArgoCD is ready."

## ---------------------------------------------------------------------------
## Step 3: Apply bootstrap application
## ---------------------------------------------------------------------------
#
#echo ""
#echo "=== Step 3: Bootstrap application ==="
#
#echo "Applying hub ApplicationSet..."
#oc apply -f "${REPO_ROOT}/bootstrap/bootstrap.yaml"
#
#echo ""
#echo "Hub bootstrap complete. ArgoCD will now manage hub cluster components."
