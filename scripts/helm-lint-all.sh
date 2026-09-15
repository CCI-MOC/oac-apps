#!/bin/bash

failed_charts=()
tmpfile=$(mktemp errXXXXXX)
trap 'rm -f "$tmpfile"' EXIT

for chart in charts/*; do
  lint_args=()
  if [[ -f "$chart/ci/test-values.yaml" ]]; then
    lint_args+=(-f "$chart/ci/test-values.yaml")
  fi

  if ! helm lint --quiet "$chart" "${lint_args[@]}" >&"$tmpfile"; then
    printf "ERROR: failed to lint %s:\n" "$chart"
    sed 's/^/  /' "$tmpfile" >&2
    failed_charts+=("$chart")
  fi
done

if [[ ${#failed_charts[@]} -gt 0 ]]; then
  printf "\n*** FAILED CHARTS ***\n\n"
  for chart in "${failed_charts[@]}"; do
    printf -- "- %s\n" "$chart"
  done

  exit 1
fi
