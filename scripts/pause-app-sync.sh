#!/bin/sh

exec argocd proj windows add default \
  --kind deny \
  --schedule "* * * * *" \
  --duration 24h \
  --applications "$1"
