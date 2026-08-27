# Multi-hub values layering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let this repo drive multiple hub clusters from one branch by templating the ApplicationSets with a per-hub `hubName` and layering hub-wide + per-cluster Helm values that are all optional.

**Architecture:** `applicationsets/` becomes a Helm chart with one required value, `hubName`, supplied by each hub's bootstrap Application. Every ApplicationSet lists an optional two-tier `valueFiles` stack (`ignoreMissingValueFiles: true`): a hub-wide default and a per-cluster override, both under `values/hub/<HUB>/`. Hosted clusters become hub-scoped under `hosted-clusters/<HUB>/`.

**Tech Stack:** Helm v4, ArgoCD ApplicationSets, bash + `find` for CI checks.

**Spec:** `docs/superpowers/specs/2026-08-26-multi-hub-values-layering-design.md`

## Global Constraints

- The current hub is `oac-dev-infra`; its managed spoke is `oac-prod`. Existing hosted clusters: `oac-prod`, `oac-dev-workload1`.
- Helm and the ApplicationSet controller both use `{{ }}`. Controller tokens (`{{component}}`, `{{name}}`, `{{server}}`, `{{.path.path}}`, and any others already present) MUST be wrapped in Helm's raw-literal escape so Helm passes them through verbatim: `` {{`{{component}}`}} ``.
- Every templated file MUST start with a guard so a missing hub name fails loudly: `{{- $hub := required "hubName must be set" .Values.hubName }}`.
- Every `helm.valueFiles` block MUST set `ignoreMissingValueFiles: true`.
- The value-layering stack, low → high precedence: chart `values.yaml` → `/values/hub/<HUB>/<component>.yaml` → `/values/hub/<HUB>/<CLUSTER>/<component>.yaml`. `<CLUSTER>` is `local-cluster` for the hub's own components and the ACM cluster name (`{{name}}`) for managed clusters.
- `repoURL` for all sources stays `https://github.com/CCI-MOC/oac-apps.git`, `targetRevision`/`revision` stays `main`.
- Do NOT change any chart under `charts/`, and do NOT alter the semantics of existing sync policies, generators, destinations, or namespaces beyond what each task specifies.
- Commit after each task. This work happens on branch `multi-hub-values-layering`.

---

### Task 1: Scaffold the Helm chart and migrate hub-components

Turns `applicationsets/` into a Helm chart and migrates the first ApplicationSet, establishing the escaping + guard pattern every later template reuses.

**Files:**
- Create: `applicationsets/Chart.yaml`
- Create: `applicationsets/values.yaml`
- Create: `applicationsets/templates/hub/hub-components.yaml`
- Delete: `applicationsets/hub/hub-components.yaml`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the chart at `applicationsets/` with value `hubName` (string, required, default `""`); the escaping/guard conventions reused by Tasks 2–3; the `templates/hub/` and `templates/managed/` layout.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-appsets-render.sh` (a reusable render check used by Tasks 1–3):

```bash
#!/bin/bash
# Render the applicationsets chart and assert hub-name wiring.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "# missing hubName must fail"
if helm template applicationsets >/dev/null 2>&1; then
  echo "FAIL: rendering without hubName should have errored"; exit 1
fi

echo "# rendering with hubName must succeed"
out=$(helm template applicationsets --set hubName=oac-dev-infra)

grep -q 'ignoreMissingValueFiles: true' <<<"$out" \
  || { echo "FAIL: ignoreMissingValueFiles not found"; exit 1; }
grep -q '/values/hub/oac-dev-infra/{{component}}.yaml' <<<"$out" \
  || { echo "FAIL: hub-wide valueFile path missing"; exit 1; }
grep -q '/values/hub/oac-dev-infra/local-cluster/{{component}}.yaml' <<<"$out" \
  || { echo "FAIL: local-cluster valueFile path missing"; exit 1; }
grep -q 'charts/{{component}}' <<<"$out" \
  || { echo "FAIL: component path token not preserved"; exit 1; }

echo "OK: appsets render checks passed"
```

Then `chmod +x scripts/test-appsets-render.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-appsets-render.sh`
Expected: FAIL — there is no `Chart.yaml` yet, so `helm template applicationsets` errors for the wrong reason (not a chart). That is an acceptable red state; proceed.

- [ ] **Step 3: Create the chart metadata and values**

`applicationsets/Chart.yaml`:

```yaml
apiVersion: v2
name: applicationsets
description: ArgoCD ApplicationSets for the OAC hub and managed clusters
type: application
version: 0.1.0
```

`applicationsets/values.yaml`:

```yaml
# hubName identifies the hub this ArgoCD instance manages. It is supplied
# per-hub by the bootstrap Application and has no safe default, so it is
# left empty here and enforced with `required` in every template.
hubName: ""
```

- [ ] **Step 4: Create the templated hub-components ApplicationSet**

`applicationsets/templates/hub/hub-components.yaml`:

```yaml
{{- $hub := required "hubName must be set" .Values.hubName }}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hub-components
  namespace: openshift-gitops
spec:
  generators:
    - list:
        elements:
          - component: openshift-gitops
          - component: nmstate
          - component: external-secrets
          - component: lvmcluster
          - component: metallb
          - component: cert-manager
          - component: patch-operator
          - component: portworx
          - component: github-oauth
          - component: github-group-sync
          - component: oac-simple-rbac
          - component: external-dns-operator
          - component: cluster-certificates
          - component: acm
          - component: hcp-config
          - component: acm-gitops-integration
          - component: acm-placements
          - component: object-storage-certificate
  template:
    metadata:
      name: "hub-{{`{{component}}`}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/CCI-MOC/oac-apps.git
        targetRevision: main
        path: "charts/{{`{{component}}`}}"
        helm:
          ignoreMissingValueFiles: true
          valueFiles:
            - "/values/hub/{{ .Values.hubName }}/{{`{{component}}`}}.yaml"
            - "/values/hub/{{ .Values.hubName }}/local-cluster/{{`{{component}}`}}.yaml"
      destination:
        server: https://kubernetes.default.svc
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

Then remove the old copy: `git rm applicationsets/hub/hub-components.yaml`

- [ ] **Step 5: Run test to verify it passes**

Run: `scripts/test-appsets-render.sh`
Expected: `OK: appsets render checks passed`

- [ ] **Step 6: Commit**

```bash
git add applicationsets/Chart.yaml applicationsets/values.yaml \
  applicationsets/templates/hub/hub-components.yaml scripts/test-appsets-render.sh
git rm --cached applicationsets/hub/hub-components.yaml 2>/dev/null || true
git commit -m "Templatize applicationsets chart with hub-components"
```

---

### Task 2: Migrate the hosted-clusters ApplicationSet

Hosted clusters must be hub-scoped so each hub's ArgoCD only creates its own. The hub name goes into the git directory generator, not just `valueFiles`.

**Files:**
- Create: `applicationsets/templates/hub/hosted-clusters.yaml`
- Delete: `applicationsets/hub/hosted-clusters.yaml`

**Interfaces:**
- Consumes: the chart + `hubName` value from Task 1.
- Produces: a git directory generator scanning `hosted-clusters/<hubName>/*`.

- [ ] **Step 1: Add the failing assertion**

Append to `scripts/test-appsets-render.sh` before the final `echo "OK:` line:

```bash
echo "# hosted-clusters generator is hub-scoped"
grep -q 'hosted-clusters/oac-dev-infra/\*' <<<"$out" \
  || { echo "FAIL: hosted-clusters generator not hub-scoped"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-appsets-render.sh`
Expected: FAIL: hosted-clusters generator not hub-scoped

- [ ] **Step 3: Create the templated hosted-clusters ApplicationSet**

`applicationsets/templates/hub/hosted-clusters.yaml`:

```yaml
{{- $hub := required "hubName must be set" .Values.hubName }}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hosted-clusters
  namespace: openshift-gitops
spec:
  goTemplate: true
  generators:
    - git:
        repoURL: https://github.com/CCI-MOC/oac-apps.git
        revision: main
        directories:
          - path: "hosted-clusters/{{ .Values.hubName }}/*"
  template:
    metadata:
      name: "cluster-{{`{{.path.basename}}`}}"
      namespace: openshift-gitops
    spec:
      project: default
      source:
        repoURL: https://github.com/CCI-MOC/oac-apps.git
        targetRevision: main
        path: charts/hosted-cluster
        helm:
          ignoreMissingValueFiles: true
          valueFiles:
            - "/{{`{{.path.path}}`}}/values.yaml"
      destination:
        server: https://kubernetes.default.svc
        namespace: clusters
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

Then: `git rm applicationsets/hub/hosted-clusters.yaml`

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-appsets-render.sh`
Expected: `OK: appsets render checks passed`

- [ ] **Step 5: Commit**

```bash
git add applicationsets/templates/hub/hosted-clusters.yaml
git rm --cached applicationsets/hub/hosted-clusters.yaml 2>/dev/null || true
git commit -m "Hub-scope the hosted-clusters applicationset"
```

---

### Task 3: Migrate the four managed ApplicationSets

All four managed sets get the same transformation: guard line, escaped controller tokens, and the hub-wide + per-`{{name}}` two-tier `valueFiles` stack.

**Files:**
- Create: `applicationsets/templates/managed/all-managed-clusters.yaml`
- Create: `applicationsets/templates/managed/github-oauth.yaml`
- Create: `applicationsets/templates/managed/gpu-clusters.yaml`
- Create: `applicationsets/templates/managed/portworx-clusters.yaml`
- Delete: the four corresponding files under `applicationsets/managed/`

**Interfaces:**
- Consumes: the chart + `hubName` value from Task 1.
- Produces: managed Applications whose `valueFiles` are `/values/hub/<hub>/<component>.yaml` then `/values/hub/<hub>/<name>/<component>.yaml`.

- [ ] **Step 1: Add the failing assertions**

Append to `scripts/test-appsets-render.sh` before the final `echo "OK:` line:

```bash
echo "# managed sets use hub-wide + per-cluster layering"
grep -q '/values/hub/oac-dev-infra/{{name}}/{{component}}.yaml' <<<"$out" \
  || { echo "FAIL: managed per-cluster valueFile path missing"; exit 1; }
for n in all-managed-clusters github-oauth gpu-clusters portworx-clusters; do
  grep -q "name: $n" <<<"$out" || { echo "FAIL: missing appset $n"; exit 1; }
done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-appsets-render.sh`
Expected: FAIL: managed per-cluster valueFile path missing

- [ ] **Step 3: Create the four templated managed ApplicationSets**

`applicationsets/templates/managed/all-managed-clusters.yaml`:

```yaml
{{- $hub := required "hubName must be set" .Values.hubName }}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: all-managed-clusters
  namespace: openshift-gitops
spec:
  generators:
    - matrix:
        generators:
          - clusterDecisionResource:
              configMapRef: acm-placement
              labelSelector:
                matchLabels:
                  cluster.open-cluster-management.io/placement: all-managed-clusters
              requeueAfterSeconds: 180
          - list:
              elements:
                - component: external-secrets
                - component: metallb
                - component: cert-manager
                - component: cluster-certificates
  template:
    metadata:
      name: "{{`{{name}}`}}-{{`{{component}}`}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/CCI-MOC/oac-apps.git
        targetRevision: main
        path: "charts/{{`{{component}}`}}"
        helm:
          ignoreMissingValueFiles: true
          valueFiles:
            - "/values/hub/{{ .Values.hubName }}/{{`{{component}}`}}.yaml"
            - "/values/hub/{{ .Values.hubName }}/{{`{{name}}`}}/{{`{{component}}`}}.yaml"
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

`applicationsets/templates/managed/github-oauth.yaml`:

```yaml
{{- $hub := required "hubName must be set" .Values.hubName }}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: github-oauth
  namespace: openshift-gitops
spec:
  generators:
    - matrix:
        generators:
          - clusterDecisionResource:
              configMapRef: acm-placement
              labelSelector:
                matchLabels:
                  cluster.open-cluster-management.io/placement: github-oauth-clusters
              requeueAfterSeconds: 180
          - list:
              elements:
                - component: github-group-sync
                - component: oac-simple-rbac
  template:
    metadata:
      name: "{{`{{name}}`}}-{{`{{component}}`}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/CCI-MOC/oac-apps.git
        targetRevision: main
        path: "charts/{{`{{component}}`}}"
        helm:
          ignoreMissingValueFiles: true
          valueFiles:
            - "/values/hub/{{ .Values.hubName }}/{{`{{component}}`}}.yaml"
            - "/values/hub/{{ .Values.hubName }}/{{`{{name}}`}}/{{`{{component}}`}}.yaml"
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

`applicationsets/templates/managed/gpu-clusters.yaml`:

```yaml
{{- $hub := required "hubName must be set" .Values.hubName }}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: gpu-clusters
  namespace: openshift-gitops
spec:
  generators:
    - matrix:
        generators:
          - clusterDecisionResource:
              configMapRef: acm-placement
              labelSelector:
                matchLabels:
                  cluster.open-cluster-management.io/placement: gpu-clusters
              requeueAfterSeconds: 180
          - list:
              elements:
                - component: nfd-operator
                - component: nvidia-gpu-operator
                - component: nvidia-maintenance-operator
                - component: nvidia-network-operator
                - component: serverless-operator
                - component: servicemesh-operator
                # component: sriov-network-operator
                - component: rhoai
  template:
    metadata:
      name: "{{`{{name}}`}}-{{`{{component}}`}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/CCI-MOC/oac-apps.git
        targetRevision: main
        path: "charts/{{`{{component}}`}}"
        helm:
          ignoreMissingValueFiles: true
          valueFiles:
            - "/values/hub/{{ .Values.hubName }}/{{`{{component}}`}}.yaml"
            - "/values/hub/{{ .Values.hubName }}/{{`{{name}}`}}/{{`{{component}}`}}.yaml"
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

`applicationsets/templates/managed/portworx-clusters.yaml`:

```yaml
{{- $hub := required "hubName must be set" .Values.hubName }}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: portworx-clusters
  namespace: openshift-gitops
spec:
  generators:
    - matrix:
        generators:
          - clusterDecisionResource:
              configMapRef: acm-placement
              labelSelector:
                matchLabels:
                  cluster.open-cluster-management.io/placement: portworx-clusters
              requeueAfterSeconds: 180
          - list:
              elements:
                - component: nmstate
                  namespace: openshift-nmstate
                - component: portworx
                  namespace: portworx
                - component: object-storage-proxy
                  namespace: object-storage-proxy
  template:
    metadata:
      name: "{{`{{name}}`}}-{{`{{component}}`}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/CCI-MOC/oac-apps.git
        targetRevision: main
        path: "charts/{{`{{component}}`}}"
        helm:
          ignoreMissingValueFiles: true
          valueFiles:
            - "/values/hub/{{ .Values.hubName }}/{{`{{component}}`}}.yaml"
            - "/values/hub/{{ .Values.hubName }}/{{`{{name}}`}}/{{`{{component}}`}}.yaml"
      destination:
        server: "{{`{{server}}`}}"
        namespace: "{{`{{namespace}}`}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
        retry:
          limit: 5
          backoff:
            duration: 30s
            factor: 2
            maxDuration: 10m
```

Then remove the old copies:

```bash
git rm applicationsets/managed/all-managed-clusters.yaml \
  applicationsets/managed/github-oauth.yaml \
  applicationsets/managed/gpu-clusters.yaml \
  applicationsets/managed/portworx-clusters.yaml
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-appsets-render.sh`
Expected: `OK: appsets render checks passed`

- [ ] **Step 5: Verify no stale ApplicationSet files remain outside templates/**

Run: `find applicationsets -maxdepth 2 -type d -name hub -o -type d -name managed | grep -v templates || true`
Expected: no output (the old `applicationsets/hub` and `applicationsets/managed` dirs are empty/gone). If empty dirs linger, they are harmless (git does not track them).

- [ ] **Step 6: Commit**

```bash
git add applicationsets/templates/managed/
git commit -m "Templatize the four managed applicationsets with hub-wide + per-cluster values"
```

---

### Task 4: Relocate the values and hosted-clusters data

Move existing per-cluster data into the new `values/hub/<HUB>/...` and `hosted-clusters/<HUB>/...` layout, and delete the empty/`{}`-only value files (absence is now legal, so they are pure clutter).

**Files:**
- Move: `values/oac-dev-infra/*.yaml` → `values/hub/oac-dev-infra/local-cluster/`
- Move: `values/oac-prod/*.yaml` → `values/hub/oac-dev-infra/oac-prod/`
- Move: `hosted-clusters/oac-prod/`, `hosted-clusters/oac-dev-workload1/` → `hosted-clusters/oac-dev-infra/`
- Delete: 11 empty/`{}` value files (listed below)

**Interfaces:**
- Consumes: the templated appsets from Tasks 1–3 (their rendered paths point here).
- Produces: the `values/hub/oac-dev-infra/{local-cluster,oac-prod}/` tree and `hosted-clusters/oac-dev-infra/*` tree that the rendered `valueFiles`/generator paths resolve against.

- [ ] **Step 1: Delete the empty/`{}`-only value files**

```bash
cd "$(git rev-parse --show-toplevel)"
git rm \
  values/oac-dev-infra/acm-gitops-integration.yaml \
  values/oac-dev-infra/nmstate.yaml \
  values/oac-dev-infra/patch-operator.yaml \
  values/oac-prod/nfd-operator.yaml \
  values/oac-prod/nmstate.yaml \
  values/oac-prod/nvidia-gpu-operator.yaml \
  values/oac-prod/nvidia-maintenance-operator.yaml \
  values/oac-prod/nvidia-network-operator.yaml \
  values/oac-prod/rhoai.yaml \
  values/oac-prod/serverless-operator.yaml \
  values/oac-prod/servicemesh-operator.yaml
```

- [ ] **Step 2: Relocate the hub-cluster values (`oac-dev-infra` → `local-cluster`)**

```bash
mkdir -p values/hub/oac-dev-infra/local-cluster
git mv values/oac-dev-infra/*.yaml values/hub/oac-dev-infra/local-cluster/
rmdir values/oac-dev-infra
```

- [ ] **Step 3: Relocate the managed-cluster values (`oac-prod`)**

```bash
mkdir -p values/hub/oac-dev-infra/oac-prod
git mv values/oac-prod/*.yaml values/hub/oac-dev-infra/oac-prod/
rmdir values/oac-prod
```

- [ ] **Step 4: Relocate hosted-clusters into the hub-scoped layout**

`values.yaml` is tracked (use `git mv`); `kubeconfig`/`password` are gitignored local files (use plain `mv` so the operator's local setup is preserved):

```bash
mkdir -p hosted-clusters/oac-dev-infra
for c in oac-prod oac-dev-workload1; do
  mkdir -p "hosted-clusters/oac-dev-infra/$c"
  # tracked file:
  git mv "hosted-clusters/$c/values.yaml" "hosted-clusters/oac-dev-infra/$c/values.yaml"
  # gitignored local files (kubeconfig, password), if present:
  for f in kubeconfig password; do
    [ -e "hosted-clusters/$c/$f" ] && mv "hosted-clusters/$c/$f" "hosted-clusters/oac-dev-infra/$c/$f"
  done
  rmdir "hosted-clusters/$c" 2>/dev/null || true
done
```

Note: keep `hosted-clusters/.gitkeep` where it is.

- [ ] **Step 5: Verify rendered paths resolve to real files**

Run:

```bash
helm template applicationsets --set hubName=oac-dev-infra >/dev/null && echo "render OK"
test -f values/hub/oac-dev-infra/local-cluster/metallb.yaml && echo "hub value present"
test -f values/hub/oac-dev-infra/oac-prod/cert-manager.yaml && echo "managed value present"
test -f hosted-clusters/oac-dev-infra/oac-prod/values.yaml && echo "hosted value present"
test ! -e values/oac-dev-infra && test ! -e values/oac-prod && echo "old dirs gone"
```

Expected: `render OK`, `hub value present`, `managed value present`, `hosted value present`, `old dirs gone`.

- [ ] **Step 6: Verify no empty value files remain**

Run:

```bash
find values/hub -name '*.yaml' -type f | while read -r f; do
  c=$(grep -vE '^\s*(#.*)?$' "$f" | tr -d '[:space:]')
  { [ -z "$c" ] || [ "$c" = "{}" ]; } && echo "STILL EMPTY: $f"
done; echo "empty scan done"
```

Expected: only `empty scan done` (no `STILL EMPTY` lines).

- [ ] **Step 7: Commit**

```bash
git add -A values hosted-clusters
git commit -m "Relocate values and hosted-clusters into hub-scoped layout"
```

---

### Task 5: Update the bootstrap Application

Point bootstrap at the chart and supply `hubName` — the single per-hub input.

**Files:**
- Modify: `bootstrap/bootstrap.yaml`

**Interfaces:**
- Consumes: the `applicationsets` chart (Tasks 1–3) with required value `hubName`.
- Produces: a bootstrap Application that renders the chart with `hubName=oac-dev-infra`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-bootstrap.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
f=bootstrap/bootstrap.yaml

grep -q 'path: applicationsets' "$f" || { echo "FAIL: path not applicationsets"; exit 1; }
grep -q 'name: hubName' "$f"        || { echo "FAIL: hubName parameter missing"; exit 1; }
grep -q 'value: oac-dev-infra' "$f" || { echo "FAIL: hubName value missing"; exit 1; }
grep -q 'recurse: true' "$f"        && { echo "FAIL: directory recurse should be gone"; exit 1; }
echo "OK: bootstrap checks passed"
```

Then `chmod +x scripts/test-bootstrap.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-bootstrap.sh`
Expected: FAIL: hubName parameter missing

- [ ] **Step 3: Rewrite the bootstrap source block**

Replace the `source:` block in `bootstrap/bootstrap.yaml` so the file reads:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootstrap
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/CCI-MOC/oac-apps.git
    targetRevision: main
    path: applicationsets
    helm:
      parameters:
        - name: hubName
          value: oac-dev-infra
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-bootstrap.sh`
Expected: `OK: bootstrap checks passed`

- [ ] **Step 5: Commit**

```bash
git add bootstrap/bootstrap.yaml scripts/test-bootstrap.sh
git commit -m "Point bootstrap at the applicationsets chart with hubName"
```

---

### Task 6: Rewrite the values-file check script

The old script asserted every component has a values file (required files) and parsed the ApplicationSets with `yq`. Both premises are gone. Rewrite it to validate the `values/hub/` tree: every value file must map to a real chart, and none may be empty.

**Files:**
- Modify: `scripts/check-values-files.sh` (full rewrite)

**Interfaces:**
- Consumes: the `values/hub/<HUB>/[<CLUSTER>/]<component>.yaml` tree (Task 4) and `charts/<component>/` dirs.
- Produces: exit 0 when the tree is clean; exit 1 listing `ORPHAN`/`EMPTY` problems.

- [ ] **Step 1: Write the rewritten script**

Replace the entire contents of `scripts/check-values-files.sh` with:

```bash
#!/bin/bash

# Validate the values/hub tree. Because ArgoCD uses
# ignoreMissingValueFiles, absent value files are legal; the risks are
# instead (a) a value file whose name does not match any chart (a typo
# that silently does nothing) and (b) empty/`{}`-only files that add
# clutter and confusion. Flag both.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

rc=0

while IFS= read -r f; do
  component=$(basename "$f" .yaml)

  # (a) orphan check: filename must correspond to a real chart
  if [[ ! -d "charts/${component}" ]]; then
    echo "ORPHAN: ${f} does not match any chart under charts/"
    rc=1
  fi

  # (b) empty check: strip comments + whitespace; flag empty or "{}"
  content=$(grep -vE '^\s*(#.*)?$' "$f" | tr -d '[:space:]')
  if [[ -z "$content" || "$content" == "{}" ]]; then
    echo "EMPTY: ${f} is empty or only {} (delete it instead)"
    rc=1
  fi
done < <(find values/hub -name '*.yaml' -type f 2>/dev/null | sort)

if [[ $rc -eq 0 ]]; then
  echo "OK: values/hub tree is clean"
fi

exit $rc
```

- [ ] **Step 2: Run it against the migrated tree (positive case)**

Run: `scripts/check-values-files.sh`
Expected: `OK: values/hub tree is clean`

- [ ] **Step 3: Verify it catches an orphan and an empty file (negative case)**

Run:

```bash
echo "foo: bar" > values/hub/oac-dev-infra/local-cluster/not-a-chart.yaml
printf '{}' > values/hub/oac-dev-infra/oac-prod/cert-manager.empty.yaml
mv values/hub/oac-dev-infra/oac-prod/cert-manager.empty.yaml \
   values/hub/oac-dev-infra/oac-prod/cert-manager.yaml.bak 2>/dev/null || true
scripts/check-values-files.sh; echo "exit=$?"
```

Expected: an `ORPHAN:` line for `not-a-chart.yaml` and `exit=1`.

- [ ] **Step 4: Clean up the negative-case fixtures**

Run:

```bash
rm -f values/hub/oac-dev-infra/local-cluster/not-a-chart.yaml \
      values/hub/oac-dev-infra/oac-prod/cert-manager.yaml.bak
scripts/check-values-files.sh
```

Expected: `OK: values/hub tree is clean`

- [ ] **Step 5: Commit**

```bash
git add scripts/check-values-files.sh
git commit -m "Rewrite check-values-files.sh for the hub-scoped optional-values model"
```

---

### Task 7: Update the README

Document the new layout, the templated chart, and how to onboard a hub.

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: docs matching the shipped structure.

- [ ] **Step 1: Update the repository-structure table**

In `README.md`, replace the `values/` rows and the `applicationsets/` description to reflect the chart + hub-scoped layout. The `values/` rows should read:

```markdown
| `values/`                  | Per-hub, per-cluster Helm values overrides (optional)            |
| `values/hub/<hub>/`        | Hub-wide defaults, applied to every cluster in that hub          |
| `values/hub/<hub>/<cluster>/` | Per-cluster overrides (`local-cluster` = the hub itself)      |
```

And note that `applicationsets/` is now a Helm chart rendered with a `hubName` value.

- [ ] **Step 2: Rewrite the "How it works" values references**

Update the bullet points so they describe the layered, optional value files instead of `values/oac-dev-infra/`. Specifically state: each Application lists a hub-wide file then a per-cluster file, both optional via `ignoreMissingValueFiles`, and the hub name comes from the bootstrap Application's `hubName` parameter.

- [ ] **Step 3: Replace the "Adding a new component" steps**

Replace that section with:

```markdown
## Adding a new component

1. Create a chart under `charts/`.
2. Add the component to the appropriate ApplicationSet template under
   `applicationsets/templates/`.
3. Only if the chart needs overrides, add `values/hub/<hub>/<component>.yaml`
   (hub-wide) and/or `values/hub/<hub>/<cluster>/<component>.yaml` (per-cluster).
   Charts with no overrides need no values file at all.
```

- [ ] **Step 4: Add an "Onboarding a hub" section**

Add after "Adding a new component":

```markdown
## Onboarding a new hub

1. Apply the bootstrap Application with the new hub's name, e.g. edit
   `bootstrap/bootstrap.yaml`'s `hubName` parameter (or override it at apply
   time) and `oc apply -f bootstrap/bootstrap.yaml`.
2. Create `values/hub/<newhub>/` and per-cluster subdirectories only where a
   chart needs an override.
3. Add `hosted-clusters/<newhub>/` if that hub runs HyperShift hosted clusters.

Everything on `main` is shared across hubs; the only per-hub input is the
`hubName` parameter in the bootstrap Application.
```

- [ ] **Step 5: Verify the docs match reality**

Run:

```bash
grep -q 'values/hub/<hub>/' README.md && echo "layout documented"
grep -q 'Onboarding a new hub' README.md && echo "onboarding documented"
grep -q 'oac-dev-infra' README.md && { echo "WARN: stale single-hub path may remain"; grep -n 'oac-dev-infra' README.md; }
```

Expected: `layout documented` and `onboarding documented`. Review any `oac-dev-infra` hits and confirm they are illustrative, not the old hard-coded `values/oac-dev-infra/` path.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "Document multi-hub values layout and hub onboarding"
```

---

## Final verification

- [ ] `helm template applicationsets --set hubName=oac-dev-infra` renders all six ApplicationSets with correct paths.
- [ ] `helm template applicationsets` (no hubName) fails with "hubName must be set".
- [ ] `scripts/test-appsets-render.sh` passes.
- [ ] `scripts/test-bootstrap.sh` passes.
- [ ] `scripts/check-values-files.sh` reports the tree is clean.
- [ ] `git status` shows no stray files; old `values/oac-dev-infra`, `values/oac-prod`, and flat `hosted-clusters/<cluster>` paths are gone.
