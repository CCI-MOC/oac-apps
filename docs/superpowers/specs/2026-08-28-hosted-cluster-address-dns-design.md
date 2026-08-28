# Hosted-cluster address assignment & DNS — design

**Date:** 2026-08-28
**Status:** Approved for planning

## Problem

Deploying a hosted cluster with `charts/hosted-cluster/` currently requires a
lot of hand-written, error-prone addressing and DNS configuration. `oac-prod`
is the worst case: four literal DNS records, a redundant OAuth hostname
override, an `issuerURL` that points at the wrong cluster, and per-service IP
plumbing. The record hostnames use two nearly identical naming conventions that
differ only by `-` vs `.` (`api-oac-prod…` internal vs `api.oac-prod…`
external), which is subtle enough to invite mistakes.

We want to minimize the per-cluster configuration required to stand up a
cluster while keeping enough flexibility that operators are never boxed in. The
work covers three things the original review named:

1. automatic generation of the hostnames used in the configuration,
2. the DNS records we actually need to create, and
3. how IP addresses are assigned to load balancers.

The arbitrary-record escape hatch (`dns.records`) is fine as-is and stays.

## Constraints (verified)

These are load-bearing and shaped the design. See `docs/hypershift-issues.md`
for the failure modes behind them.

- **Only `APIServer` supports `LoadBalancer` publishing on the Agent
  platform.** `OAuthServer`, `Konnectivity`, and `Ignition` support only
  `NodePort` and `Route`; the HyperShift reconciler rejects `LoadBalancer` for
  them on non-Azure platforms. Any "auto-assign a LoadBalancer per service"
  scheme is therefore a non-starter for everything except the API.
- **External endpoints require manual firewall configuration.** An external IP
  is a firewall NAT to an internal address, so every externally reachable
  service needs a *stable, known* internal target. This is why the API keeps a
  pinned IP rather than an auto-assigned one.
- **We cannot run split-horizon DNS.** Internal and external reachability are
  distinguished by using two different names, never by resolving one name
  differently per client.
- **`namedCertificate` for a hostname already in the KAS default serving-cert
  SANs is rejected** — but only for names we add *ourselves* as extra SANs
  (the old NodePort `nodePort.address` workaround). The `kubeAPIServerDNSName`
  plus its own `namedCertificate` is the intended, working path and is
  unaffected.

## Goals / non-goals

**Goals**

- A cluster's per-cluster addressing input collapses to essentially: cluster
  name, the API's pinned internal IP, and the API's external firewall IP.
- Zero per-cluster DNS for OAuth, Konnectivity, and Ignition.
- One uniform hostname convention where internal-vs-external facing is
  signalled by the *domain* (or an explicit word for the API), never by a
  one-character `-`/`.` difference.
- HCP routes are served only by the dedicated `hosted-clusters`
  IngressController, so mapping an external address to an HCP route never
  inadvertently exposes it on the default router.

**Non-goals**

- Split-horizon DNS.
- Auto-assigning LoadBalancer IPs for services that need firewall mappings.
- Reworking the `dns.records` arbitrary-record feature.
- A shared hub-wide wildcard *certificate* for the external domain (noted as a
  future optimization below, but not built here).

## Naming convention

Every service-specific name is a single DNS label `<service>-<cluster>` under a
domain that encodes its facing. Facing is read from the domain; the API
additionally carries an explicit `internal`/`external` word so its two names
are unmistakable.

| Name | Resolves to | Mechanism |
|---|---|---|
| `api-external-<cluster>.<hcpExternalDomain>` | API external firewall IP | explicit record (overrides external wildcard); this is `kubeAPIServerDNSName` |
| `api-internal-<cluster>.<hcpInternalDomain>` | pinned API LoadBalancer IP | explicit record (overrides internal wildcard); becomes a KAS serving-cert SAN |
| `oauth-<cluster>.<hcpExternalDomain>` | router external firewall IP | `*.<hcpExternalDomain>` wildcard |
| `konnectivity-<cluster>.<hcpInternalDomain>` | router internal IP | `*.<hcpInternalDomain>` wildcard |
| `ignition-<cluster>.<hcpInternalDomain>` | router internal IP | `*.<hcpInternalDomain>` wildcard |

`<hcpInternalDomain>` and `<hcpExternalDomain>` are new hub-level values (see
below). The two wildcards are the only DNS an operator creates by hand, and
they are created **once per hub**, not per cluster.

## Solution overview

### 1. APIServer — LoadBalancer with a pinned IP

`APIServer` becomes a `LoadBalancer` by default (its `serviceDefaults`
`defaultType` changes from `NodePort` to `LoadBalancer`). It is the only
service that can be, and it is the only one that needs a stable literal IP for
the firewall.

- `services.APIServer.ipAddress` — the pinned internal LoadBalancer IP. Drives
  the MetalLB pool (below), is set as `loadBalancer.hostname =
  api-internal-<cluster>.<hcpInternalDomain>`, and produces the internal
  explicit DNS record.
- `services.APIServer.externalIpAddress` — the external firewall IP. Sets
  `kubeAPIServerDNSName = api-external-<cluster>.<hcpExternalDomain>` and
  produces the external explicit DNS record.

`ipAddress` is optional at the template level (MetalLB would auto-assign from
the default pool if omitted), but for any externally reachable cluster it is
the expected input — the firewall needs to know it in advance. Setting a
non-`APIServer` service's `ipAddress` is now a hard error (it can never be a
LoadBalancer).

### 2. OAuth / Konnectivity / Ignition — Route via the dedicated router

These stay `Route`. Their hostnames derive from the naming table:
`oauth-<cluster>.<hcpExternalDomain>` (external-facing, browser OAuth),
`konnectivity-<cluster>.<hcpInternalDomain>` and
`ignition-<cluster>.<hcpInternalDomain>` (internal-facing). They produce **no
per-cluster DNS records**: the hub-wide wildcards cover them.

All three are admitted by the dedicated `hosted-clusters` IngressController,
which has a single LoadBalancer IP (the MetalLB `hosted-clusters-ingress`
pool, `10.20.3.10` in dev). Both wildcards ultimately reach that one router:

- `*.<hcpInternalDomain>` → `10.20.3.10` directly (Konnectivity, Ignition, and
  in-cluster callers).
- `*.<hcpExternalDomain>` → the router's external firewall IP, which NATs to
  `10.20.3.10` (browser OAuth).

The router matches routes by their explicit hostname, so it does not care that
the two wildcards live in different domains, nor that its own `spec.domain` is
unrelated to either (its domain is only used for auto-generated hostnames,
which we never rely on).

### 3. Adopting the dedicated router (and getting off the default one)

The `hosted-clusters` IngressController already exists in
`charts/hcp-config/` with the correct shard selectors
(`hypershift.openshift.io/hosted-control-plane`) but is not yet in use — today
HCP routes land on the *default* router. Two changes complete the adoption:

- **Enable it per hub** via `hcp-config` values (already the pattern:
  `ingressController.enabled: true`, a `domain`, and the MetalLB
  `hosted-clusters-ingress` pool that pins its LoadBalancer to `10.20.3.10`).
- **Exclude HCP routes from the default router.** Add a `namespaceSelector`
  with `hypershift.openshift.io/hosted-control-plane DoesNotExist` to the
  repo-managed default IngressController in
  `charts/cluster-certificates/templates/ingresscontroller.yaml`. Without this,
  an HCP route can be admitted by *both* routers and answered on the default
  router's IP — exactly the private-route exposure we want to prevent. The
  default controller keeps admitting all normal application routes (they lack
  the label).

### 4. IP assignment / MetalLB

MetalLB pinning narrows to `APIServer` only (the sole LoadBalancer service).
Because only `APIServer` may carry `ipAddress`, the existing
`ipaddresspool.yaml` and `service-patches.yaml` loops naturally reduce to it;
we tighten them to target `APIServer` explicitly and fail on any other service
with an `ipAddress`.

We **keep the proven redhat-cop Patch-operator pinning** (annotate the
`kube-apiserver` service with `metallb.universe.tf/address-pool`) rather than
switching to a MetalLB `serviceAllocation` selector. `serviceAllocation` +
priority would work (the `kube-apiserver` service is the one HCP service
HyperShift labels) and would remove the Patch-operator scaffolding, but it
requires careful pool-priority tuning so the default auto-assign pool doesn't
grab the address first. The annotation approach is unambiguous and already in
service. *(Noted as a possible future simplification, not adopted here.)*

### 5. Certificates

- **API:** `certificate-api.yaml` issues a Let's Encrypt cert for
  `kubeAPIServerDNSName` (now `api-external-<cluster>.<hcpExternalDomain>`),
  wired as a `namedCertificate` on the KAS. Mechanism unchanged; only the
  derived name moves. The **internal** name (`api-internal-<cluster>`) gets no
  Let's Encrypt cert — it is covered by the KAS default serving cert (internal
  CA, trusted by the nodes), which avoids the in-cluster-TLS and
  SAN-conflict failure modes.
- **OAuth:** `certificate-oauth.yaml` issues a Let's Encrypt cert for
  `oauth-<cluster>.<hcpExternalDomain>`; mechanism unchanged, name moves.

Both external certs now live under `<hcpExternalDomain>`, which must be
solvable by the `letsencrypt-prod-dns01` issuer — the same requirement OAuth's
cert already imposes, so the API just joins it.

### 6. DNS records produced

- **Hub-wide, created once by the operator:** `*.<hcpInternalDomain>` →
  `10.20.3.10`, and `*.<hcpExternalDomain>` → router external firewall IP.
- **Per-cluster, auto-generated** (`dns.autoGenerate`): exactly two external-dns
  shadow Services for the API — `api-internal-<cluster>` → `ipAddress`, and
  `api-external-<cluster>` → `externalIpAddress`. Both are explicit records
  that override the corresponding wildcard. OAuth/Konnectivity/Ignition
  generate **nothing**.
- **Per-cluster, manual:** `dns.records` stays for genuinely arbitrary entries,
  e.g. the guest cluster's ingress wildcard `*.apps.<cluster>.<baseDomain>` →
  ingress firewall IP.

## Hub-level values

Two new required hub values, consumed by both `hosted-cluster` and (for the
wildcard/router wiring) documented alongside `hcp-config`:

- `hcpInternalDomain` — e.g. `hcp-int.infra.oac.int.massopen.cloud`
- `hcpExternalDomain` — e.g. `hcp.oac.massopen.cloud`

They are added to `hosted-clusters/<hub>/values.yaml` next to the existing
`baseDomain` / `managementCluster`, enforced with `required` in a helper
(mirroring `hosted-cluster.baseDomain`), and fail closed if unset. The router's
external firewall IP is a hub-level fact recorded in the same file / firewall
runbook.

## Per-cluster interface: before and after

**Before (`oac-prod`):**

```yaml
clusterName: oac-prod
issuerURL: "https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/oac-dev-workload0"  # wrong cluster
services:
  OAuthServer:
    servicePublishingStrategy:
      type: Route
      route:
        hostname: oauth-oac-prod.apps.infra.oac.int.massopen.cloud   # redundant override
oauth: { github: {...} }
nodePools: [...]
clusterLabels: [...]
dns:
  enabled: true
  records:
    - { name: api,          hostname: api.oac-prod.apps.infra.oac.int.massopen.cloud,        target: 129.10.5.101 }
    - { name: oauth,        hostname: oauth-oac-prod.apps.infra.oac.int.massopen.cloud,      target: 129.10.5.101 }
    - { name: ingress,      hostname: "*.apps.oac-prod.apps.infra.oac.int.massopen.cloud",   target: 129.10.5.102 }
    - { name: api-internal, hostname: api-oac-prod.apps.infra.oac.int.massopen.cloud,        targets: [10.20.2.110, 10.20.2.206, 10.20.2.141] }
```

**After:**

```yaml
clusterName: oac-prod
services:
  APIServer:
    ipAddress: 10.20.3.11          # pinned internal LB → api-internal-oac-prod.<hcpInternalDomain>
    externalIpAddress: 129.10.5.101 # firewall IP     → api-external-oac-prod.<hcpExternalDomain>
oauth: { github: {...} }
nodePools: [...]
clusterLabels: [...]
dns:
  enabled: true
  autoGenerate: true
  records:
    - name: ingress               # guest-cluster ingress wildcard, stays manual
      hostname: "*.apps.oac-prod.apps.infra.oac.int.massopen.cloud"
      target: 129.10.5.102
```

The `issuerURL` override is deleted (the template defaults it correctly to the
cluster's own OIDC bucket), the redundant OAuth override is deleted, and three
of four DNS records disappear.

## Chart changes (by file)

- `charts/hosted-cluster/templates/_helpers.tpl` — add `hcpInternalDomain` /
  `hcpExternalDomain` required helpers; extend `serviceDefaults` so each
  service knows its facing domain; teach hostname derivation to emit the
  single-label `<service>-<cluster>.<domain>` names, with `APIServer`
  special-cased to produce both `api-internal-…` and `api-external-…`.
- `charts/hosted-cluster/templates/hostedcluster.yaml` — `APIServer`
  `defaultType` → `LoadBalancer`; set `loadBalancer.hostname` to the internal
  name; default `kubeAPIServerDNSName` to the external name; OAuth/Konnectivity/
  Ignition route hostnames from the new derivation.
- `charts/hosted-cluster/templates/dns-records.yaml` — `autoGenerate` emits
  only the two API records (internal + external); no records for the routed
  services.
- `charts/hosted-cluster/templates/ipaddresspool.yaml`,
  `service-patches.yaml` — restrict to `APIServer`; error on any other service
  carrying `ipAddress`.
- `charts/hosted-cluster/templates/certificate-api.yaml`,
  `certificate-oauth.yaml` — follow the new derived hostnames (no structural
  change).
- `charts/hosted-cluster/values.yaml` — document the new `services.APIServer`
  `ipAddress`/`externalIpAddress` contract; `hcpInternalDomain` /
  `hcpExternalDomain` default to `""` (required, fail-closed).
- `charts/cluster-certificates/templates/ingresscontroller.yaml` — add the
  default-router `namespaceSelector` exclusion.
- `hosted-clusters/oac-dev-infra/values.yaml` — add `hcpInternalDomain` /
  `hcpExternalDomain`.
- Unit tests (`charts/hosted-cluster/tests/unit/*`) updated for every rendering
  change: hostnames, publishing strategies, the two-record autoGenerate output,
  APIServer-only MetalLB, and the fail-closed guards.

## Migration

**`oac-dev-workload1`** (already `LoadBalancer`, `autoGenerate: true`): adopt
the new interface — set `externalIpAddress` if it needs external reach; it
otherwise picks up the new derived names automatically. Validate the whole flow
here first.

**`oac-prod`** (live, currently all-NodePort): this is a maintenance-window
operation.

1. Create the two hub wildcards and the firewall NATs (router `:443`, API
   `:6443`); enable the dedicated router and confirm it holds `10.20.3.10`; add
   the default-router exclusion.
2. Update `oac-prod` values to the "after" form above (API → LoadBalancer +
   pinned/external IPs; delete the OAuth and `issuerURL` overrides; keep the
   ingress record).
3. The OAuth hostname moves to `<hcpExternalDomain>` → OAuth cert reissues
   **and the GitHub OAuth app callback URL must be updated** to the new
   hostname.
4. The API republish (NodePort → LoadBalancer) regenerates KAS serving-cert
   SANs and changes how nodes reach the API; expect brief API disruption and
   node reconnection. Do it in a window, after workload1 has proven the path.

## Verification items (resolve during planning/implementation)

1. **KAS SANs for LoadBalancer.** Confirm HyperShift adds
   `servicePublishingStrategy.loadBalancer.hostname` (and the LB IP) to the KAS
   default serving-cert SANs on the Agent platform, so `api-internal-<cluster>`
   works for in-cluster/node TLS. Prior art: `oac-dev-workload1` already sets
   `loadBalancer.hostname`.
2. **Shard labels.** Confirm HyperShift labels the HCP namespace
   (`clusters-<cluster>`) and/or the route objects with
   `hypershift.openshift.io/hosted-control-plane` so both the dedicated-router
   selectors and the default-router exclusion match.
3. **Passthrough routes.** Confirm OAuth/Konnectivity/Ignition routes are
   passthrough, so the dedicated router forwards TLS to pods that present their
   own certs (OAuth: the LE cert; Konnectivity/Ignition: internal certs the
   nodes trust).
4. **OAuth named cert.** Confirm the existing OAuth `namedCertificate` wiring
   still applies unchanged with the new hostname.

## Testing & guardrails

- `helm template charts/hosted-cluster` with representative values (pinned API,
  external IP, autoGenerate) renders the expected HostedCluster strategies, two
  API DNS records, APIServer-only MetalLB objects, and both certs — per the
  standing "verify templates after changes" rule.
- `helm template` fails closed when `hcpInternalDomain` / `hcpExternalDomain`
  are unset, and when a non-`APIServer` service carries `ipAddress`.
- `helm template charts/cluster-certificates` renders the default router with
  the exclusion selector.
- `helm-unittest` suites updated/extended for all of the above.
- Confirm the charts still build and existing CI passes.

## Out of scope

- A shared hub-wide wildcard **certificate** for `*.<hcpExternalDomain>` that
  both OAuth and the external API could reference (fewer LE issuances). The new
  naming makes this a clean follow-up; not built here.
- Switching APIServer MetalLB pinning from the Patch operator to
  `serviceAllocation` + priority.
- Any change to the `dns.records` arbitrary-record feature.
