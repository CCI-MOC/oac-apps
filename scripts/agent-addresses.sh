#!/bin/bash

# Display the agent uuid (metadata.name), spec.hostname, the BMC address, and
# the interface addresses for every agent in the hardware-inventory namespace.
# One row per agent; all interface addresses are collapsed into a single
# comma-separated list.

: "${CLOUDKIT_AGENT_NAMESPACE:=hardware-inventory}"

{
  echo "UUID HOSTNAME RESOURCE_CLASS BMC ADDRESSES"
  oc -n "$CLOUDKIT_AGENT_NAMESPACE" get agent -o json | jq -r '
    .items[]
    | [
        .metadata.name,
        (.spec.hostname // "-"),
        (.metadata.labels."openstack/resource-class"),
        (.status.inventory.bmcAddress // "-"),
        ([(.status.inventory.interfaces // [])[]
          | .ipV4Addresses + .ipV6Addresses] | add // [] | join(",") | if . == "" then "-" else . end)
      ]
    | @tsv
  '
} | column -t
