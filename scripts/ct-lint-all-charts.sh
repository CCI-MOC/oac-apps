#!/bin/bash

ct_options=()

if ! type yamale >&/dev/null; then
  ct_options+=(--validate-chart-schema=false)
fi

exec ct lint --all --chart-dirs charts --validate-maintainers=false --excluded-charts operator-library "${ct_options[@]}"
