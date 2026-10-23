#!/bin/bash

# charts/compliance groups charts; it is not one itself
find charts/* charts/compliance/* -maxdepth 0 -type d -exec test -f {}/Chart.yaml \; -print0 |
  xargs -r0 -P0 -n1 helm dependency update >/dev/null
