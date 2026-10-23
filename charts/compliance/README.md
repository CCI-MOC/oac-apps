# Compliance charts

Charts that harden hubs and clusters for NIST 800-171, HIPAA and FIPS. Each
is its own chart, since they deploy to different places (the hub, every
spoke, or a hosted cluster's namespace on the hub).

- `hosted-cluster`: hub-side resources for one hosted cluster, in its
  `clusters-<name>` namespace. Deployed by the `hosted-cluster-compliance`
  ApplicationSet.
