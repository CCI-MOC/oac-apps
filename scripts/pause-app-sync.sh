#!/bin/sh

if [ -z "$1" ]; then
  echo "ERROR: you must provide an app name" >&2
  exit 1
fi

exec argocd proj windows add default \
  --kind deny \
  --schedule "* * * * *" \
  --duration 24h \
  --applications "$1"
