#!/usr/bin/env bash
set -euo pipefail

# Extracts the OIDC discovery document and JWKS from an OpenShift cluster,
# rewrites the issuer URL to point to an S3 bucket, and writes the files
# to OUTPUT_DIR for upload.

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${AWS_REGION:=us-east-1}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"

S3_ISSUER_URL="https://${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com/${CLUSTER_NAME}"

mkdir -p "${OUTPUT_DIR}/.well-known"

echo "Extracting OIDC discovery document from cluster..."
oc get --raw /.well-known/openid-configuration | \
  jq --arg issuer "${S3_ISSUER_URL}" '.issuer = $issuer | .jwks_uri = ($issuer + "/keys.json")' \
  > "${OUTPUT_DIR}/.well-known/openid-configuration"

echo "Extracting JWKS from cluster..."
oc get --raw /openid/v1/jwks > "${OUTPUT_DIR}/keys.json"

echo "OIDC config written to ${OUTPUT_DIR}"
echo "  Discovery: ${OUTPUT_DIR}/.well-known/openid-configuration"
echo "  JWKS:      ${OUTPUT_DIR}/keys.json"
