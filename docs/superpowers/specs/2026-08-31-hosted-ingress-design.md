# Hosted-cluster guest ingress — design

**Date:** 2026-08-31
**Status:** Approved for planning

## Problem

Each hosted (guest) cluster needs a stable LoadBalancer address for its default
IngressController. Today that address is pinned by a MetalLB `IPAddressPool`
named `default-ingress`, defined inline in the generic per-cluster MetalLB values
file, e.g. `values/oac-prod-infra/oac-prod-workload0/metallb.yaml`:

```yaml
addressPools:
  - name: default
    addresses:
      - 10.20.13.200-10.20.13.250
  - name: default-ingress
    addresses:
      - 10.20.13.10/32
    serviceAllocation:
      namespaceSelectors:
        - matchLabels:
            kubernetes.io/metadata.name: openshift-ingress
      serviceSelectors:
        - matchLabels:
            ingresscontroller.operator.openshift.io/owning-ingresscontroller: default
```

This creates two problems:

1. **Scattered configuration.** Everything else about a hosted cluster — its API
   IP, ingress `externalIpAddress`, DNS, node pools, feature labels — lives in a
   single per-cluster file, `hosted-clusters/<hub>/<cluster>/values.yaml`. The
   guest ingress pool address is the one piece defined somewhere else, in a file
   consumed by a different ApplicationSet. There is no single source of truth for
   a hosted cluster.

2. **Ingress setup is buried in the generic MetalLB chart.** Pinning the guest
   router's LoadBalancer is a distinct concern — "set up ingress on this guest
   cluster" — but it is currently expressed as one entry in a general-purpose
   address-pool list, so it cannot evolve independently.

We want to configure the guest ingress pool from the same single per-cluster file
that defines the rest of the hosted cluster, and to own the guest ingress setup
in a purpose-built chart rather than the generic MetalLB chart.

## Solution overview

Two pieces, mirroring the hub-side `hcp-config` pattern (which already owns the
`hosted-clusters-ingress` pool as "one unit of hosted-cluster ingress
configuration," deliberately separate from the generic `metallb` chart):

1. **New chart `charts/hosted-ingress`**, deployed *to the guest cluster*, that
   renders the MetalLB `IPAddressPool` + `L2Advertisement` pinning the guest's
   default IngressController LoadBalancer. It reads its address from the
   single-source hosted-cluster values file.

2. **New ApplicationSet `applicationsets/templates/hub/hosted-ingress.yaml`**,
   which targets each guest cluster and feeds it that same per-cluster file.

The address becomes a field in `hosted-clusters/<hub>/<cluster>/values.yaml` —
the single source of truth — and the old `default-ingress` pool is removed from
the generic MetalLB values.

### Why not extend the existing paths?

- **Teach the generic `metallb` chart to read the hosted-cluster file** —
  rejected. It overloads a general-purpose chart with a hosted-cluster-specific
  responsibility.

- **Add the hosted-cluster file to the `all-managed-clusters` ApplicationSet's
  `valueFiles`** — rejected. That ApplicationSet applies one shared `valueFiles`
  template to every component in its matrix (`metallb`, `cert-manager`, …).
  Adding `/hosted-clusters/<hub>/<name>/values.yaml` there would leak the entire
  hosted-cluster value set (oauth, nodePools, services, …) into every other
  chart. A dedicated ApplicationSet lets exactly one chart read that file.

## Single source of truth

The guest router's internal LoadBalancer IP is added to the existing `ingress`
block of `hosted-clusters/<hub>/<cluster>/values.yaml`:

```yaml
ingress:
  # Externally reachable IP for the guest ingress wildcard (drives DNS on the
  # hub via the hosted-cluster chart).
  externalIpAddress: 129.10.5.104
  # Internal LoadBalancer IP for the guest's default IngressController router,
  # pinned by MetalLB on the guest cluster. Consumed by the hosted-ingress app
  # (NOT the hosted-cluster chart, which runs on the hub and cannot create a
  # guest-side pool). CIDR form, consistent with the previous metallb pool.
  poolAddress: 10.20.13.10/32
```

`externalIpAddress` (the firewall NAT IP, `129.10.5.104`) and `poolAddress` (the
internal router LB IP, `10.20.13.10/32`) are distinct values that both describe
this cluster's ingress; co-locating them keeps the whole hosted cluster
described in one file.

**The hosted-cluster chart does not declare `ingress.poolAddress`.** Helm
silently ignores values a chart does not consume, so the field lives in the
shared file and is declared (with a fail-closed default) only by the
`hosted-ingress` chart that uses it. The comment above documents what reads it.

## Chart: `charts/hosted-ingress`

Scope for now is the MetalLB pool only (YAGNI). The name is generic so the chart
can later grow to own the guest IngressController resource (domain, replicas)
should we ever stop pinning the default controller.

`values.yaml`:

```yaml
ingress:
  # Internal LoadBalancer IP (or MetalLB address form: CIDR or range) for the
  # guest's default IngressController router. When empty the chart renders
  # nothing (fail closed). Supplied per-cluster from
  # hosted-clusters/<hub>/<cluster>/values.yaml.
  poolAddress: ""
```

`templates/ingress-addresspool.yaml` renders only when `poolAddress` is set:

```yaml
{{- with .Values.ingress.poolAddress }}
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-ingress
  namespace: metallb-system
  # These annotations match the pool the metallb chart renders today, so the
  # migration is a clean ownership handoff with no ArgoCD diff churn.
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
    argocd.argoproj.io/sync-wave: "2"
spec:
  addresses:
    - {{ . }}
  serviceAllocation:
    namespaceSelectors:
      - matchLabels:
          kubernetes.io/metadata.name: openshift-ingress
    serviceSelectors:
      - matchLabels:
          ingresscontroller.operator.openshift.io/owning-ingresscontroller: default
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  # A distinct name from the metallb chart's combined "l2advertisement"; the two
  # never co-own an L2Advertisement (only the IPAddressPool is shared across the
  # cutover). Advertising the same pool from two L2Advertisements during overlap
  # is harmless.
  name: default-ingress
  namespace: metallb-system
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
    argocd.argoproj.io/sync-wave: "2"
spec:
  ipAddressPools:
    - default-ingress
{{- end }}
```

### Resource naming: reuse `default-ingress` (deliberate)

The chart reuses the exact pool/advertisement name (`default-ingress`) the
generic `metallb` chart creates today, rather than a fresh name like
`hosted-ingress`. This reverses the `hcp-config` "distinct names, never co-own"
convention, on purpose, because the constraint here is a live migration, not a
greenfield resource:

- MetalLB rejects two `IPAddressPool`s advertising the same address. A distinct
  name plus the same address is therefore an invalid overlap — migrating that way
  would require deleting the old pool *before* the new one exists, i.e. a brief
  window where the guest router's LoadBalancer address is unpinned.
- Reusing the name means the object is byte-identical and is simply handed from
  one Application to the other. No duplicate-address conflict, no unpin window.

The trade-off is a transient window where both Applications
(`<cluster>-metallb`, once its manifest still lists the pool, and
`<cluster>-hosted-ingress`) consider the object theirs. That co-ownership is
purely transitional: once the `metallb` values no longer render `default-ingress`
(same commit), exactly one Application owns it. The `hcp-config` rule exists to
prevent *permanent* co-ownership of a greenfield resource; it does not apply to a
one-time ownership handoff.

## ApplicationSet: `applicationsets/templates/hub/hosted-ingress.yaml`

Reuses the existing `all-managed-clusters` ACM placement (defined in
`charts/acm-gitops-integration`) via a `clusterDecisionResource` generator, which
yields `{{name}}` (the ACM cluster name, equal to the
`hosted-clusters/<hub>/<name>` directory name) and `{{server}}` (the guest
cluster API to deploy to). It deploys the single `hosted-ingress` chart — no
component matrix — so it can point `valueFiles` at the hosted-cluster file:

```yaml
{{- $hub := required "hubName must be set" .Values.hubName }}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hosted-ingress
  namespace: openshift-gitops
spec:
  generators:
    - clusterDecisionResource:
        configMapRef: acm-placement
        labelSelector:
          matchLabels:
            cluster.open-cluster-management.io/placement: all-managed-clusters
        requeueAfterSeconds: 180
  template:
    metadata:
      name: "{{`{{name}}`}}-hosted-ingress"
    spec:
      project: default
      source:
        repoURL: https://github.com/CCI-MOC/oac-apps.git
        targetRevision: main
        path: charts/hosted-ingress
        helm:
          ignoreMissingValueFiles: true
          valueFiles:
            - "/hosted-clusters/{{ $hub }}/values.yaml"
            - "/hosted-clusters/{{ $hub }}/{{`{{name}}`}}/values.yaml"
      destination:
        server: "{{`{{server}}`}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        retry:
          limit: 5
          backoff:
            duration: 30s
            factor: 2
            maxDuration: 10m
```

Notes:

- The chart consumes only `ingress.poolAddress`; the many other keys in the
  hosted-cluster file are ignored by Helm.
- `ignoreMissingValueFiles: true` plus the fail-closed template means a managed
  cluster selected by the placement but with no hosted-cluster values file (or no
  `poolAddress`) renders nothing — safe for any non-hosted managed cluster the
  placement happens to select.
- The two brace worlds (Helm `{{ }}` vs. ApplicationSet-controller `{{ }}`)
  follow the repo convention: controller tokens are wrapped in Helm's raw-literal
  escape `` {{`...`}} `` and each template guards on `hubName`.

## Migration (behavior-preserving, sequenced)

For each guest cluster currently pinned via a `default-ingress` pool (today:
`oac-prod-workload0`):

1. Add `ingress.poolAddress` to `hosted-clusters/<hub>/<cluster>/values.yaml`
   using the **same** address the `metallb` chart currently uses.
2. Remove the `default-ingress` entry from
   `values/<hub>/<cluster>/metallb.yaml`, leaving the `default` range pool.

**Ordering constraint.** MetalLB rejects two `IPAddressPool`s that advertise the
same address; the chart reuses the `default-ingress` name specifically to avoid
that overlap (see "Resource naming" above). The migration is therefore an
ownership handoff of a byte-identical object, not a create/delete of two
differently named pools. Concretely:

- Land the values change (steps 1–2) and the new ApplicationSet in the same
  commit, so the `metallb` app stops rendering `default-ingress` in the same
  change that the `hosted-ingress` app starts rendering it.
- Both Applications (`<cluster>-metallb` and `<cluster>-hosted-ingress`) will
  briefly both consider the `default-ingress` object theirs. Since the rendered
  object is byte-identical, the pinned address does not change; the only risk is
  transient ArgoCD ownership churn, not an ingress outage. Watch that the
  `metallb` app's prune of `default-ingress` and the `hosted-ingress` app's
  create settle to a single owner (sync the `hosted-ingress` app first if
  sequencing manually).
- Verify on the live guest after cutover that exactly one `IPAddressPool
  default-ingress` exists and the router service keeps its address.

This is called out here as a risk to handle deliberately in the implementation
plan for the running oac-prod guest; it is not a decision to make now.

## Testing & guardrails

- **helm-unittest** for `charts/hosted-ingress`:
  - `poolAddress` set → renders exactly one `IPAddressPool` and one
    `L2Advertisement`, both named `default-ingress`, with the given address and
    the default-controller serviceAllocation selectors.
  - `poolAddress` empty/unset → renders nothing (fail closed).
- **ApplicationSet render:** `helm template applicationsets --set
  hubName=oac-prod-infra` renders the new ApplicationSet with the expected
  `valueFiles` paths and destination `{{server}}`; rendering with no `hubName`
  fails (asserts the `required` guard). Extend
  `applicationsets/tests/unit/` accordingly.
- Confirm the chart builds and the full existing test suite / CI passes.

## Out of scope

- Managing the guest IngressController resource itself (replicas, domain, custom
  controllers). The chart is named generically to allow this later.
- A hosted-cluster-specific ACM placement. Reusing `all-managed-clusters` with
  fail-closed rendering is sufficient; a dedicated placement is a safe follow-up
  if we want to stop selecting non-hosted clusters.
- Migrating the generic `default` range pool out of the `metallb` chart; only the
  `default-ingress` pool moves.
