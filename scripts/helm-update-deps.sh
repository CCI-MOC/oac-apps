#!/bin/bash

find charts -name Chart.yaml -not -path 'charts/*/charts/*' -printf '%h\0' |
  xargs -r0 -P0 -n1 helm dependency update >/dev/null
