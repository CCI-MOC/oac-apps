#!/bin/bash

find charts/* -maxdepth 0 -type d -print0 |
  xargs -r0 -P0 -n1 helm dependency update >/dev/null
