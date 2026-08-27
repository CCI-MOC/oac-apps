#!/bin/bash

# Copy an AWS Secrets Manager secret to a new name. Handles secrets that use
# either SecretString or SecretBinary. The original secret's description is
# preserved on the copy. By default the original is left in place; pass -d to
# delete the source after a successful copy (i.e. to rename the secret).

set -euo pipefail

usage() {
  echo "Usage: $0 [-d] <existing-secret-name> <new-secret-name>" >&2
  echo "  -d    delete the source secret after a successful copy" >&2
  exit 1
}

DELETE_SRC=false
while getopts ':d' opt; do
  case "$opt" in
    d) DELETE_SRC=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

SRC=${1:-}
DST=${2:-}

[ -n "$SRC" ] || usage
[ -n "$DST" ] || usage

if [ "$SRC" = "$DST" ]; then
  echo "ERROR: source and destination names are identical" >&2
  exit 1
fi

# Work in a private temp dir so the plaintext secret never touches a
# world-readable location, and clean it up on exit.
workdir=$(mktemp -d)
chmod 700 "$workdir"
trap 'rm -rf "$workdir"' EXIT

# Fetch the existing secret value and its metadata.
secret_json=$(aws secretsmanager get-secret-value --secret-id "$SRC")
description=$(aws secretsmanager describe-secret --secret-id "$SRC" \
  --query 'Description' --output json | jq -r '. // empty')

create_args=(--name "$DST")
if [ -n "$description" ]; then
  create_args+=(--description "$description")
fi

if [ "$(jq 'has("SecretString")' <<<"$secret_json")" = "true" ]; then
  jq -j '.SecretString' <<<"$secret_json" >"$workdir/secret"
  create_args+=(--secret-string "file://$workdir/secret")
elif [ "$(jq 'has("SecretBinary")' <<<"$secret_json")" = "true" ]; then
  # SecretBinary is base64-encoded in the API response; decode to raw bytes.
  jq -j '.SecretBinary' <<<"$secret_json" | base64 -d >"$workdir/secret"
  create_args+=(--secret-binary "fileb://$workdir/secret")
else
  echo "ERROR: secret '$SRC' has neither SecretString nor SecretBinary" >&2
  exit 1
fi

# Create the copy first; if this fails (e.g. the name already exists) we bail
# out before touching the original.
aws secretsmanager create-secret "${create_args[@]}" >/dev/null
echo "Copied '$SRC' to '$DST'"

# The copy succeeded. Only remove the original if -d was given. Force deletion
# so the old name is freed immediately rather than lingering through a recovery
# window.
if [ "$DELETE_SRC" = true ]; then
  aws secretsmanager delete-secret --secret-id "$SRC" \
    --force-delete-without-recovery >/dev/null
  echo "Deleted '$SRC'"
fi
