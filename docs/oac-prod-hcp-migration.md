# oac-prod migration to the new HCP address/DNS architecture (deferred)

**Status:** Deferred. Not yet applied. Do during a maintenance window (or as
part of the planned oac-infra-dev redeploy).

**Date deferred:** 2026-08-28

## Why this is deferred

The chart rework in `charts/hosted-cluster/` (branch
`spec/hosted-cluster-address-dns`, Tasks 1–5) flips the `APIServer` default from
`NodePort` to `LoadBalancer` and derives all HCP hostnames from two hub-level
domains (`hcpInternalDomain` / `hcpExternalDomain`). `oac-prod` is the one live
cluster still on the old all-NodePort, hand-written-DNS interface. Migrating its
values file republishes the live API and moves the OAuth hostname — a disruptive
operation that must be coordinated.

The immediate auto-sync risk is currently neutralised out-of-band: **the ArgoCD
application controller on `oac-infra-dev` has been scaled to zero replicas**, so
nothing in this repo drives a sync. The longer-term plan is to **redeploy
`oac-infra-dev` and its hosted clusters** cleanly against the new architecture;
this migration is the `oac-prod` part of that, and can either be folded into the
redeploy or done as its own windowed cutover if the cluster is kept in place.

**Source of truth:**
- Design/spec: `docs/superpowers/specs/2026-08-28-hosted-cluster-address-dns-design.md` (see "Migration")
- Plan: `docs/superpowers/plans/2026-08-28-hosted-cluster-address-dns.md` (Task 6)
- Background failure modes: `docs/hypershift-issues.md`

## What applying this does (the disruption)

1. **API republish, NodePort → LoadBalancer.** Regenerates the KAS default
   serving-cert SANs and changes how nodes reach the API. Expect brief API
   disruption and node reconnection. Do it in a window.
2. **OAuth hostname moves** to `oauth-oac-prod.<hcpExternalDomain>` (from the
   current `oauth-oac-prod.apps.infra.oac.int.massopen.cloud`). The OAuth
   Let's Encrypt cert reissues **and the GitHub OAuth app callback URL must be
   updated** to the new hostname, or GitHub login breaks.
3. **DNS records change** to the derived names (see below); three of the four
   hand-written records go away.

## Prerequisites (must be true before applying)

- [ ] Hub value `hcpInternalDomain` is set on `hosted-clusters/oac-dev-infra/values.yaml`
      (already present: `hcp.infra.oac.int.massopen.cloud`).
- [ ] If OAuth is exposed through a firewall NAT under a **separate** external
      wildcard, set `hcpExternalDomain` on the same hub file. If external and
      internal reach the router at the same IP (no NAT split), leave it unset
      (it inherits `hcpInternalDomain`). Note: oac-prod's OAuth is browser-facing
      via a firewall IP today, which normally forces a distinct external domain —
      confirm the intended facing before deciding.
- [ ] Hub wildcards created **once per hub** by the operator:
      - `*.<hcpInternalDomain>` → the `hosted-clusters` router MetalLB IP (`10.20.3.10` in dev)
      - `*.<hcpExternalDomain>` → the router's external firewall IP (NATs to `10.20.3.10`)
- [ ] Firewall NATs in place: router `:443` (OAuth/ingress) and API `:6443`.
- [ ] The dedicated `hosted-clusters` IngressController is enabled and holds
      `10.20.3.10`, and the default-router exclusion (Task 4,
      `charts/cluster-certificates/templates/ingresscontroller.yaml`) is applied.
      **Caveat:** confirm the dedicated router *admits* oac-prod's HCP routes
      before the default router *de-admits* them, or OAuth/Ignition/Konnectivity
      break during the switch.
- [ ] `<hcpExternalDomain>` is solvable by the `letsencrypt-prod-dns01` issuer
      (same requirement OAuth's cert already imposes).

## Cutover inputs to gather (values only the operator holds)

These are NOT known/committed anywhere — confirm real values before editing:

| Input | Maps to | Notes |
|---|---|---|
| Pinned **internal** API LoadBalancer IP | `services.APIServer.ipAddress` → `api-internal-oac-prod.<hcpInternalDomain>` + drives MetalLB pool | **New** address from the hosted-clusters MetalLB range (cf. workload1 uses `10.20.3.11`). NOT the old NodePort node IPs. |
| API **external** firewall IP | `services.APIServer.externalIpAddress` → `api-external-oac-prod.<hcpExternalDomain>` (= `kubeAPIServerDNSName`) | Old NodePort era value was `129.10.5.101`; confirm it's still the firewall IP. |
| Guest-cluster ingress firewall IP | manual `dns.records` ingress wildcard target | Old value `129.10.5.102`; confirm. |

### Current (before) state — reference only

`hosted-clusters/oac-dev-infra/oac-prod/values.yaml` as of the rebase onto main
commit `13305cf` ("Allow arbitrary oath configuration"). The **oauth block has
already been modernised** to `oauth.identityProviders` + `externalSecrets` (the
old `oauth.github` + `secretPath` form is gone) — **keep that block verbatim**;
only the `services`/`dns`/`issuerURL` parts below are the old address/DNS
interface this migration replaces.

```yaml
clusterName: oac-prod

issuerURL: "https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/oac-dev-workload0"  # WRONG cluster; delete

services:
  OAuthServer:
    servicePublishingStrategy:
      type: Route
      route:
        hostname: oauth-oac-prod.apps.infra.oac.int.massopen.cloud   # redundant override; delete

oauth:                                   # KEEP AS-IS (from main 13305cf)
  identityProviders:
    - name: github
      type: GitHub
      mappingMethod: claim
      github:
        clientID: "1bd59d9431653b8aaccd"
        clientSecret:
          name: oac-prod-github-oauth-client-secret
        teams:
          - CCI-MOC/open-accelerator-admins

externalSecrets:                         # KEEP AS-IS (from main 13305cf)
  - name: oac-prod-github-oauth-client-secret
    spec:
      target:
        name: oac-prod-github-oauth-client-secret
      data:
        - secretKey: clientSecret
          remoteRef:
            key: cluster/oac-infra-dev/hostedcluster/oac-prod/github-oauth-client-secret

# nodePools, clusterLabels unchanged
dns:
  enabled: true
  records:
    - { name: api,          hostname: api.oac-prod.apps.infra.oac.int.massopen.cloud,  target: 129.10.5.101 }
    - { name: oauth,        hostname: oauth-oac-prod.apps.infra.oac.int.massopen.cloud, target: 129.10.5.101 }
    - { name: ingress,      hostname: "*.apps.oac-prod.apps.infra.oac.int.massopen.cloud", target: 129.10.5.102 }
    - { name: api-internal, hostname: api-oac-prod.apps.infra.oac.int.massopen.cloud, targets: [10.20.2.110, 10.20.2.206, 10.20.2.141] }
```

## The migration steps

### Step 1 — confirm cutover inputs
Gather the table above and decide on `hcpExternalDomain`. Substitute the real
values into Step 2 (the IPs below are placeholders).

### Step 2 — rewrite `hosted-clusters/oac-dev-infra/oac-prod/values.yaml`

```yaml
clusterName: oac-prod

services:
  APIServer:
    ipAddress: 10.20.3.12          # pinned internal LB IP  — CONFIRM REAL VALUE
    externalIpAddress: 129.10.5.101 # API external firewall IP — CONFIRM REAL VALUE

oauth:                                   # unchanged from main 13305cf
  identityProviders:
    - name: github
      type: GitHub
      mappingMethod: claim
      github:
        clientID: "1bd59d9431653b8aaccd"
        clientSecret:
          name: oac-prod-github-oauth-client-secret
        teams:
          - CCI-MOC/open-accelerator-admins

externalSecrets:                         # unchanged from main 13305cf
  - name: oac-prod-github-oauth-client-secret
    spec:
      target:
        name: oac-prod-github-oauth-client-secret
      data:
        - secretKey: clientSecret
          remoteRef:
            key: cluster/oac-infra-dev/hostedcluster/oac-prod/github-oauth-client-secret

nodePools:
  - name: compute
    replicas: 3
    agentLabelSelector:
      openstack/resource-class: fc830
      massopen.cloud/cluster: oac-prod
  - name: gpu
    replicas: 2
    agentLabelSelector:
      openstack/resource-class: lenovo-sd665nv3-h100
      massopen.cloud/cluster: oac-dev-workload0

clusterLabels:
  - gpu
  - github-oauth
  - portworx

dns:
  enabled: true
  autoGenerate: true
  records:
    - name: ingress                # guest-cluster ingress wildcard, stays manual
      hostname: "*.apps.oac-prod.apps.infra.oac.int.massopen.cloud"
      target: 129.10.5.102         # ingress firewall IP — CONFIRM REAL VALUE
```

What changed vs. before:
- Deleted the `issuerURL` override — the template defaults it correctly to the
  cluster's own OIDC bucket (`…/oac-prod`).
- Deleted the redundant `OAuthServer` Route hostname override — now derived.
- Deleted the manual `api`, `oauth`, and `api-internal` DNS records — the API's
  two records are auto-generated (`autoGenerate: true`) and OAuth is covered by
  the hub wildcard. Only the guest-cluster ingress wildcard stays manual.
- API is now a pinned LoadBalancer with an external firewall IP.

What is **unchanged** and must be preserved:
- The `oauth.identityProviders` and `externalSecrets` blocks (added on main by
  `13305cf`). Do NOT revert to the old `oauth.github` + `secretPath` form — that
  mechanism and the `github-oauth-secret.yaml` template were removed on main;
  the client secret now flows through an `ExternalSecret`.

> The `clientID`/`teams` above are copied from the current live file
> (`1bd59d9431653b8aaccd`, `CCI-MOC/open-accelerator-admins`) in its post-`13305cf`
> `identityProviders` form — trust the live file, not the plan's Task 6 listing
> (which predates the arbitrary-oauth change and used the old form).

### Step 3 — render to verify (no live apply)

```bash
helm template charts/hosted-cluster \
  -f hosted-clusters/oac-dev-infra/values.yaml \
  -f hosted-clusters/oac-dev-infra/oac-prod/values.yaml \
  > /tmp/oac-prod.yaml && echo OK
```

Expected: `OK`, with
`issuerURL: "https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/oac-prod"`,
the API published as `LoadBalancer` with
`loadBalancer.hostname: api-internal-oac-prod.<hcpInternalDomain>`,
`kubeAPIServerDNSName: api-external-oac-prod.<hcpExternalDomain>`, and exactly
two `external-dns` API shadow Services (`dns-apiserver-internal-oac-prod`,
`dns-apiserver-external-oac-prod`).

### Step 4 — cutover
- Update the **GitHub OAuth app callback URL** to the new
  `oauth-oac-prod.<hcpExternalDomain>` hostname.
- Apply (or include in the redeploy). If ArgoCD auto-sync is re-enabled on the
  hub, this is where the API republish happens — do it in the window.
- Commit as its own change: `Migrate oac-prod to LoadBalancer API and derived DNS`.

## Verification items to confirm during the window

(From the spec's "Verification items"; re-check against the live cluster.)
1. HyperShift adds `loadBalancer.hostname` + LB IP to the KAS serving-cert SANs
   on the Agent platform (so `api-internal-oac-prod` works for node/in-cluster TLS).
2. HyperShift labels the HCP namespace/routes with
   `hypershift.openshift.io/hosted-control-plane` (dedicated-router selectors +
   default-router exclusion both depend on it).
3. OAuth/Konnectivity/Ignition routes are passthrough.
4. The existing OAuth `namedCertificate` wiring still applies with the new hostname.
