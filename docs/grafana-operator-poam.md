# Grafana operator: POA&M item

Project Grafanas (`user-projects`, `grafana.enabled`) run through the
community Grafana operator (`grafana-operator` chart, deployed to every
managed cluster by `all-managed-clusters`). On a compliant cluster that is
a known gap. This records it as a Plan of Action and Milestones (POA&M)
item instead of removing the operator. The alternative, Grafana without
the operator, is #230.

## The gap

| Weakness | Detail |
|---|---|
| No FIPS claim for the operator | grafana-operator 5.25.0 is a community build from Grafana Labs. Its CSV has no `fips-compliant` annotation, and the binary is upstream Go without FIPS crypto (not built with CGO_ENABLED) |
| No FIPS build of Grafana | The operator runs `docker.io/grafana/grafana:11.3.0`, built with a Go too old for FIPS support. Grafana's own connection to thanos-querier uses that crypto |
| Datasource token in cleartext | The operator pushes each project's datasource (with its service account token) into Grafana's admin API on port 3000, over plain HTTP inside the cluster |
| Registry allowlist | A compliant cluster's allowed registries do not include `docker.io`, so the Grafana image cannot be pulled there without an exception or a mirror |

Controls: SC-13 (cryptographic protection) and SC-8 (transmission
confidentiality) in NIST 800-53; 3.13.8 and 3.13.11 in 800-171.

## Compensating controls in place

- Port 3000 is open only to the operator's namespace: the project
  NetworkPolicy in `user-projects` and the `allow-grafana-operator-ingress`
  rule of the AdminNetworkPolicy in `restrict-tenant-networks`, both
  limited to that port.
- People never reach port 3000. They come in through the router and Red
  Hat's oauth-proxy in the Grafana pod (FIPS crypto through RHEL), which
  checks their rights in the project namespace.
- The datasource uses thanos-querier's tenancy port, 9092, pinned to the
  project namespace. The token's service account has view in that
  project and `system:auth-delegator` (creating TokenReviews and
  SubjectAccessReviews, for the proxy), so a leaked one reads that
  project and no other.

## Scope

Compliant clusters only, and only projects with `grafana.enabled`. No
other cluster changes.

## Remediation

| Milestone | Owner | Target date |
|---|---|---|
| Decide: keep the operator under this item, or move to #230 (Grafana without the operator) | *to fill in* | *to fill in* |
| If kept: allow or mirror the Grafana image for compliant clusters | *to fill in* | *to fill in* |
| Recheck for a FIPS build of the operator or of Grafana | *to fill in* | *to fill in* |

Closing #230 and merging this means the operator stays everywhere and
this item stays open. Merging #230 removes the operator and makes this
item unnecessary.
