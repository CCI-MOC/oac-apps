# Hosted-cluster Guest Ingress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure each hosted (guest) cluster's default-ingress MetalLB pool from the single per-cluster `hosted-clusters/<hub>/<cluster>/values.yaml` file, via a dedicated `hosted-ingress` chart and ApplicationSet, replacing the inline `default-ingress` pool in the generic `metallb` chart's values.

**Architecture:** A new `charts/hosted-ingress` chart renders a MetalLB `IPAddressPool` + `L2Advertisement` (fail-closed on an unset address) that pins the guest's default IngressController LoadBalancer. A new `hosted-ingress` ApplicationSet deploys that chart to each guest cluster, feeding it the hosted-cluster values file so the pool address lives beside the rest of the cluster's config. The migration reuses the existing pool name (`default-ingress`) so the object is handed off between ArgoCD Applications with no address change.

**Tech Stack:** Helm charts, helm-unittest, ArgoCD ApplicationSets (ACM `clusterDecisionResource` generator), MetalLB.

**Spec:** `docs/superpowers/specs/2026-08-31-hosted-ingress-design.md`

## Global Constraints

- ArgoCD ApplicationSet controller tokens (`{{name}}`, `{{server}}`) must survive Helm rendering untouched — wrap them in Helm's raw-literal escape: `` {{`{{name}}`}} ``.
- Every ApplicationSet template begins with `{{- $hub := required "hubName must be set" .Values.hubName }}` so a missing hub name fails loudly.
- The `hosted-ingress` chart must fail closed: render **nothing** when `ingress.poolAddress` is empty/unset.
- The MetalLB `IPAddressPool` named `default-ingress` rendered by `hosted-ingress` must be byte-identical to what the `metallb` chart renders today (same name, namespace, annotations, addresses, serviceAllocation) so the migration is a clean ownership handoff. Reference annotations copied verbatim: `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` and `argocd.argoproj.io/sync-wave: "2"`.
- Repo uses `oc` over `kubectl`; ArgoCD resources belong to `application.argoproj.io` — use fully qualified names when interacting with the cluster.
- Run helm-unittest for a single chart with: `helm unittest -f 'tests/unit/*_test.yaml' <chart-dir>`.

---

### Task 1: `hosted-ingress` chart

**Files:**
- Create: `charts/hosted-ingress/Chart.yaml`
- Create: `charts/hosted-ingress/values.yaml`
- Create: `charts/hosted-ingress/templates/ingress-addresspool.yaml`
- Create: `charts/hosted-ingress/ci/test-values.yaml`
- Test: `charts/hosted-ingress/tests/unit/ingress_addresspool_test.yaml`

**Interfaces:**
- Consumes: nothing (leaf chart).
- Produces: a chart at `charts/hosted-ingress` consuming a single value `ingress.poolAddress` (string; a MetalLB address form — CIDR or range). When set it renders an `IPAddressPool` and `L2Advertisement`, both named `default-ingress` in namespace `metallb-system`; when empty it renders zero documents. Task 2's ApplicationSet points at this chart path.

- [ ] **Step 1: Create the chart scaffold (Chart.yaml + values.yaml)**

`charts/hosted-ingress/Chart.yaml`:

```yaml
apiVersion: v2
name: hosted-ingress
description: MetalLB address pool pinning a hosted (guest) cluster's default ingress router.
type: application
version: 0.1.0
```

`charts/hosted-ingress/values.yaml`:

```yaml
ingress:
  # Internal LoadBalancer IP (or any MetalLB address form: CIDR or range) for
  # the guest's default IngressController router. When empty the chart renders
  # nothing (fail closed). Supplied per-cluster from
  # hosted-clusters/<hub>/<cluster>/values.yaml.
  poolAddress: ""
```

- [ ] **Step 2: Write the failing test**

`charts/hosted-ingress/tests/unit/ingress_addresspool_test.yaml`:

```yaml
suite: hosted-ingress default-ingress MetalLB pool
templates:
  - templates/ingress-addresspool.yaml
tests:
  - it: should render exactly the IPAddressPool and L2Advertisement when an address is set
    set:
      ingress:
        poolAddress: 10.20.13.10/32
    asserts:
      - hasDocuments:
          count: 2

  - it: should pin the pool to the default ingress router with matching annotations
    set:
      ingress:
        poolAddress: 10.20.13.10/32
    documentSelector:
      path: kind
      value: IPAddressPool
    asserts:
      - equal:
          path: metadata.name
          value: default-ingress
      - equal:
          path: metadata.namespace
          value: metallb-system
      - equal:
          path: metadata.annotations["argocd.argoproj.io/sync-options"]
          value: SkipDryRunOnMissingResource=true
      - equal:
          path: metadata.annotations["argocd.argoproj.io/sync-wave"]
          value: "2"
      - contains:
          path: spec.addresses
          content: 10.20.13.10/32
      - equal:
          path: spec.serviceAllocation.namespaceSelectors[0].matchLabels["kubernetes.io/metadata.name"]
          value: openshift-ingress
      - equal:
          path: spec.serviceAllocation.serviceSelectors[0].matchLabels["ingresscontroller.operator.openshift.io/owning-ingresscontroller"]
          value: default

  - it: should advertise the pool via its own L2Advertisement
    set:
      ingress:
        poolAddress: 10.20.13.10/32
    documentSelector:
      path: kind
      value: L2Advertisement
    asserts:
      - equal:
          path: metadata.name
          value: default-ingress
      - contains:
          path: spec.ipAddressPools
          content: default-ingress

  - it: should render nothing when no address is set
    asserts:
      - hasDocuments:
          count: 0
```

- [ ] **Step 3: Run test to verify it fails**

Run: `helm unittest -f 'tests/unit/*_test.yaml' charts/hosted-ingress`
Expected: FAIL — the "count: 2" and IPAddressPool/L2Advertisement assertions fail because `templates/ingress-addresspool.yaml` does not exist yet (0 documents rendered).

- [ ] **Step 4: Write the template**

`charts/hosted-ingress/templates/ingress-addresspool.yaml`:

```yaml
{{- with .Values.ingress.poolAddress }}
# MetalLB address pool pinning the guest's default IngressController router to a
# stable LoadBalancer address. Owned by this dedicated chart rather than the
# generic metallb chart so guest ingress setup is one unit of configuration.
# Named "default-ingress" to match the pool the metallb chart rendered before
# this chart existed, so the migration is a clean ownership handoff.
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-ingress
  namespace: metallb-system
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

- [ ] **Step 5: Run test to verify it passes**

Run: `helm unittest -f 'tests/unit/*_test.yaml' charts/hosted-ingress`
Expected: PASS (4 tests).

- [ ] **Step 6: Add ci/test-values.yaml for ct lint**

`charts/hosted-ingress/ci/test-values.yaml`:

```yaml
ingress:
  poolAddress: 10.20.13.10/32
```

- [ ] **Step 7: Verify chart lints and renders**

Run: `helm template charts/hosted-ingress -f charts/hosted-ingress/ci/test-values.yaml`
Expected: renders one `IPAddressPool` and one `L2Advertisement`, both named `default-ingress`.

Run: `helm template charts/hosted-ingress`
Expected: renders nothing (empty output) — confirms fail-closed default.

- [ ] **Step 8: Commit**

```bash
git add charts/hosted-ingress
git commit -m "Add hosted-ingress chart for guest default-ingress MetalLB pool"
```

---

### Task 2: `hosted-ingress` ApplicationSet

**Files:**
- Create: `applicationsets/templates/hub/hosted-ingress.yaml`
- Test: `applicationsets/tests/unit/hosted-ingress_test.yaml`

**Interfaces:**
- Consumes: the `applicationsets` chart's `hubName` value; the `charts/hosted-ingress` chart path from Task 1; the `all-managed-clusters` ACM placement (defined in `charts/acm-gitops-integration`).
- Produces: an `ApplicationSet` named `hosted-ingress` that deploys `charts/hosted-ingress` to each guest cluster (`{{server}}` from the placement decision), layering `/hosted-clusters/<hub>/values.yaml` under `/hosted-clusters/<hub>/{{name}}/values.yaml`, both optional via `ignoreMissingValueFiles`.

- [ ] **Step 1: Write the failing test**

`applicationsets/tests/unit/hosted-ingress_test.yaml`:

```yaml
suite: hosted-ingress ApplicationSet
templates:
  - templates/hub/hosted-ingress.yaml

tests:
  - it: should fail closed when hubName is not set
    asserts:
      - failedTemplate:
          errorPattern: hubName must be set

  - it: should render the hosted-ingress ApplicationSet
    set:
      hubName: oac-dev-infra
    asserts:
      - hasDocuments:
          count: 1
      - containsDocument:
          kind: ApplicationSet
          apiVersion: argoproj.io/v1alpha1
          name: hosted-ingress

  - it: should select guest clusters via the all-managed-clusters placement
    set:
      hubName: oac-dev-infra
    asserts:
      - equal:
          path: spec.generators[0].clusterDecisionResource.configMapRef
          value: acm-placement
      - equal:
          path: spec.generators[0].clusterDecisionResource.labelSelector.matchLabels["cluster.open-cluster-management.io/placement"]
          value: all-managed-clusters

  - it: should deploy the hosted-ingress chart to the guest cluster
    set:
      hubName: oac-dev-infra
    asserts:
      - equal:
          path: spec.template.metadata.name
          value: "{{name}}-hosted-ingress"
      - equal:
          path: spec.template.spec.source.path
          value: charts/hosted-ingress
      - equal:
          path: spec.template.spec.destination.server
          value: "{{server}}"

  - it: should layer hub-level values under per-cluster values from the hosted-cluster file, both optional
    set:
      hubName: oac-dev-infra
    asserts:
      - equal:
          path: spec.template.spec.source.helm.ignoreMissingValueFiles
          value: true
      - equal:
          path: spec.template.spec.source.helm.valueFiles[0]
          value: "/hosted-clusters/oac-dev-infra/values.yaml"
      - equal:
          path: spec.template.spec.source.helm.valueFiles[1]
          value: "/hosted-clusters/oac-dev-infra/{{name}}/values.yaml"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `helm unittest -f 'tests/unit/*_test.yaml' applicationsets`
Expected: FAIL — `templates/hub/hosted-ingress.yaml` does not exist, so the new suite errors / renders no documents.

- [ ] **Step 3: Write the ApplicationSet template**

`applicationsets/templates/hub/hosted-ingress.yaml`:

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
            # Single source of truth: the hosted cluster's own values file. The
            # chart consumes only ingress.poolAddress; all other keys are ignored.
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

- [ ] **Step 4: Run test to verify it passes**

Run: `helm unittest -f 'tests/unit/*_test.yaml' applicationsets`
Expected: PASS — the new `hosted-ingress` suite passes and all pre-existing applicationset suites still pass.

- [ ] **Step 5: Verify the ApplicationSet renders with a hub name**

Run: `helm template applicationsets --set hubName=oac-prod-infra -s templates/hub/hosted-ingress.yaml`
Expected: renders one `ApplicationSet` named `hosted-ingress`; `valueFiles` are `/hosted-clusters/oac-prod-infra/values.yaml` and `/hosted-clusters/oac-prod-infra/{{name}}/values.yaml`; `destination.server` is `{{server}}`.

- [ ] **Step 6: Commit**

```bash
git add applicationsets/templates/hub/hosted-ingress.yaml applicationsets/tests/unit/hosted-ingress_test.yaml
git commit -m "Add hosted-ingress ApplicationSet"
```

---

### Task 3: Migrate oac-prod-workload0 to the single-source pool

**Files:**
- Modify: `hosted-clusters/oac-prod-infra/oac-prod-workload0/values.yaml` (add `ingress.poolAddress`)
- Modify: `values/oac-prod-infra/oac-prod-workload0/metallb.yaml` (remove the `default-ingress` pool)

**Interfaces:**
- Consumes: the `hosted-ingress` chart (Task 1) and ApplicationSet (Task 2).
- Produces: the guest ingress pool address defined once, in the hosted-cluster values file; the generic `metallb` values no longer render a `default-ingress` pool.

- [ ] **Step 1: Add `poolAddress` to the hosted-cluster values file**

In `hosted-clusters/oac-prod-infra/oac-prod-workload0/values.yaml`, update the existing `ingress:` block from:

```yaml
ingress:
  # Guest ingress wildcard (*.apps.oac-prod-workload0.hcp.oac.massopen.cloud)
  # resolves to this externally reachable IP; the firewall NATs :80/:443 to the
  # guest router's LoadBalancer (10.20.12.10), which is pinned by MetalLB on the
  # hosted cluster itself -- not from this chart.
  externalIpAddress: 129.10.5.104
```

to:

```yaml
ingress:
  # Guest ingress wildcard (*.apps.oac-prod-workload0.hcp.oac.massopen.cloud)
  # resolves to this externally reachable IP; the firewall NATs :80/:443 to the
  # guest router's LoadBalancer (10.20.13.10), pinned by MetalLB on the guest
  # cluster via the hosted-ingress app (see poolAddress below).
  externalIpAddress: 129.10.5.104
  # Internal LoadBalancer IP for the guest's default IngressController router.
  # Consumed by the hosted-ingress app (NOT the hosted-cluster chart, which runs
  # on the hub). This is the single source of truth for the guest ingress pool.
  poolAddress: 10.20.13.10/32
```

- [ ] **Step 2: Verify the hosted-ingress chart renders the pool from the real values files**

Run: `helm template charts/hosted-ingress -f hosted-clusters/oac-prod-infra/values.yaml -f hosted-clusters/oac-prod-infra/oac-prod-workload0/values.yaml`
Expected: renders the `IPAddressPool`/`L2Advertisement` named `default-ingress` with `spec.addresses: [10.20.13.10/32]`.

- [ ] **Step 3: Verify the hosted-cluster chart still renders with the extra key**

Run: `helm template charts/hosted-cluster -f hosted-clusters/oac-prod-infra/values.yaml -f hosted-clusters/oac-prod-infra/oac-prod-workload0/values.yaml >/dev/null && echo OK`
Expected: `OK` — the hosted-cluster chart ignores the unknown `ingress.poolAddress` key and renders without error.

- [ ] **Step 4: Remove the `default-ingress` pool from the metallb values**

Replace the entire contents of `values/oac-prod-infra/oac-prod-workload0/metallb.yaml` with (drop the `default-ingress` list item, keep `default`):

```yaml
addressPools:
  - name: default
    addresses:
      - 10.20.13.200-10.20.13.250
```

- [ ] **Step 5: Verify the metallb chart no longer renders default-ingress**

Run: `helm template charts/metallb -f values/oac-prod-infra/oac-prod-workload0/metallb.yaml | grep -c 'name: default-ingress' || true`
Expected: `0`.

Run: `helm template charts/metallb -f values/oac-prod-infra/oac-prod-workload0/metallb.yaml | grep -c 'name: default$' || true`
Expected: `1` — the `default` range pool is still rendered.

- [ ] **Step 6: Commit (both changes together — see cutover note)**

Both edits land in one commit so the `metallb` app stops rendering `default-ingress` in the same change the `hosted-ingress` app starts rendering it — an ownership handoff of a byte-identical object, avoiding a MetalLB duplicate-address conflict.

```bash
git add hosted-clusters/oac-prod-infra/oac-prod-workload0/values.yaml values/oac-prod-infra/oac-prod-workload0/metallb.yaml
git commit -m "Move oac-prod-workload0 guest ingress pool to hosted-ingress"
```

**Live cutover note (for whoever syncs ArgoCD, not a code step):** After this merges, both `oac-prod-workload0-metallb` and `oac-prod-workload0-hosted-ingress` briefly consider the `default-ingress` `IPAddressPool` theirs. Because the rendered object is byte-identical, the pinned address does not change. If sequencing manually, sync `oac-prod-workload0-hosted-ingress` first, then let `oac-prod-workload0-metallb` prune. Afterward verify on the guest that exactly one `IPAddressPool default-ingress` exists (`oc get ipaddresspool -n metallb-system default-ingress`) and the openshift-ingress router service keeps `10.20.13.10`.

---

### Task 4: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full helm-unittest suite**

Run: `./scripts/helm-unittest-all.sh`
Expected: all suites pass, including the two new ones.

- [ ] **Step 2: Lint all charts**

Run: `./scripts/ct-lint-all-charts.sh`
Expected: passes; `hosted-ingress` lints cleanly (uses `ci/test-values.yaml`).

- [ ] **Step 3: Confirm no stray `default-ingress` remains in metallb values**

Run: `grep -rl 'default-ingress' values/ || echo "none"`
Expected: `none`.
