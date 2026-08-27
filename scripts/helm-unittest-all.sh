#!/bin/bash

find ./* -path '*/tests/unit/*_test.yaml' | sed 's|/tests/unit/.*||' | sort -u |
  xargs -r helm unittest -f 'tests/unit/*_test.yaml'
