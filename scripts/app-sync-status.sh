#!/bin/sh

: "${ARGOCD_PATH:=argocd}"

{
  echo NAME SYNC HEALTH REVISION LAST_SYNC
  exec $ARGOCD_PATH app list -o json | jq -r '
    .[] | [.metadata.name, .status.sync.status, .status.health.status, .status.sync.revision[:7], .status.history[-1].deployedAt] | @tsv
  '
} | column -t
