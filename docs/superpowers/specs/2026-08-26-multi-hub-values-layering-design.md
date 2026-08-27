# Multi-hub values layering — design

**Date:** 2026-08-26
**Status:** Approved for planning

## Problem

The repository must support multiple hub clusters, but the current design is
effectively limited to a single hub. Two things bake in the single-hub
assumption:

1. `applicationsets/hub/hub-components.yaml` hard-codes the hub's value path as
   `/values/oac-dev-infra/{{component}}.yaml` — `oac-dev-infra` *is* the hub.
2. `applicationsets/hub/hosted-clusters.yaml` uses a flat `hosted-clusters/*`
   git directory generator, so every hub's ArgoCD would try to create every
   hub's hosted clusters.

We want hub-wide defaults for the charts we deploy, followed by values specific
to the deployed cluster, across multiple hubs — without resorting to one branch
per hub (which invites version skew).

A secondary constraint drove the original hesitation: when ArgoCD lists
`valueFiles`, each file is **required** by default. For charts with no obvious
tunable it is easy to forget to create the values file, causing sync failures.

## Solution overview

Two independent mechanisms, combined:

1. **`ignoreMissingValueFiles: true`** (ArgoCD Helm source option, since Argo CD
   2.3) makes every listed value file optional. This lets us list a layered
   stack of value files where any layer may be absent, eliminating the
   "required file" problem entirely. See:
   https://argo-cd.readthedocs.io/en/stable/user-guide/helm/#values-files

2. **Templated ApplicationSets** — `applicationsets/` becomes a small Helm chart
   with a single required value, `hubName`. Each hub's bootstrap Application
   supplies its own `hubName`; everything on `main` stays byte-for-byte
   identical across hubs. This is "Option A" from the design discussion, chosen
   over a cluster-secret label (Option B) because it handles hub-components and
   managed sets uniformly with the least per-hub surface area, and over an
   ApplicationSet plugin generator (Option C) because it adds no standing
   infrastructure.

## Value layering model

A single, uniform two-tier override stack applies to **every** component
deployment, layered on top of the chart's own `values.yaml`:

```
values/
  hub/
    <HUB>/
      <component>.yaml              # tier 1: hub-wide default (all clusters in this hub)
      <CLUSTER>/
        <component>.yaml            # tier 2: per-cluster override
```

Precedence, low → high:

1. chart `values.yaml` (the implicit "common" layer, shipped with the chart)
2. hub-wide default: `values/hub/<HUB>/<component>.yaml`
3. per-cluster override: `values/hub/<HUB>/<CLUSTER>/<component>.yaml`

Every override file (tiers 2 and 3) is optional via `ignoreMissingValueFiles`.

### Naming conventions

- **The hub cluster's own components.** The hub-components set targets the local
  cluster (`https://kubernetes.default.svc`), which has no ACM decision to give
  it a name. The convention is `local-cluster` — exactly what ACM already calls
  the hub — so the hub cluster's per-cluster overrides live at
  `values/hub/<HUB>/local-cluster/<component>.yaml`. Components that only ever
  run on the hub (e.g. `acm`, `hcp-config`, `openshift-gitops`,
  `acm-placements`) can use the hub-wide tier and skip the per-cluster file.

- **Managed (spoke) clusters** use their ACM cluster name (`{{name}}` from the
  placement decision) as `<CLUSTER>`.

- **Hosted clusters** become hub-scoped: `hosted-clusters/<HUB>/<cluster>/`.

### Future extension (out of scope now)

An explicit cross-hub `common/` tier (`values/common/<component>.yaml`) can be
added later as a single prepended `valueFiles` entry. Because layering is purely
additive and every entry is optional, going from this two-tier model to a
three-tier model is a one-line change to the templates plus creating files only
where a genuine cross-hub default exists. We are not building it now (YAGNI); the
chart's own `values.yaml` serves as the common layer today.

## ApplicationSets as a Helm chart

`applicationsets/` gains a `Chart.yaml` and `values.yaml`, and the existing
manifests move under `templates/`:

```
applicationsets/
  Chart.yaml
  values.yaml                    # hubName: "" (must be overridden at bootstrap)
  templates/
    hub/hub-components.yaml
    hub/hosted-clusters.yaml
    managed/all-managed-clusters.yaml
    managed/github-oauth.yaml
    managed/gpu-clusters.yaml
    managed/portworx-clusters.yaml
```

### Two brace worlds

Helm and the ApplicationSet controller both use `{{ }}`. Helm renders
`.Values.hubName` at bootstrap/render time; the ApplicationSet controller tokens
(`{{component}}`, `{{name}}`, `{{server}}`, `{{.path.path}}`) must survive Helm
untouched, so they are wrapped in Helm's raw-literal escape:
`` {{`{{component}}`}} ``.

Each template begins with a guard so a missing hub name fails loudly rather than
silently producing `/values/hub//...`:

```yaml
{{- $hub := required "hubName must be set" .Values.hubName }}
```

### hub-components (excerpt)

```yaml
path: "charts/{{`{{component}}`}}"
helm:
  ignoreMissingValueFiles: true
  valueFiles:
    - "/values/hub/{{ .Values.hubName }}/{{`{{component}}`}}.yaml"
    - "/values/hub/{{ .Values.hubName }}/local-cluster/{{`{{component}}`}}.yaml"
```

### managed sets (excerpt)

`{{name}}` is the spoke's ACM cluster name from the placement decision:

```yaml
helm:
  ignoreMissingValueFiles: true
  valueFiles:
    - "/values/hub/{{ .Values.hubName }}/{{`{{component}}`}}.yaml"
    - "/values/hub/{{ .Values.hubName }}/{{`{{name}}`}}/{{`{{component}}`}}.yaml"
```

### hosted-clusters — hub name goes into the generator

```yaml
generators:
  - git:
      repoURL: https://github.com/CCI-MOC/oac-apps.git
      revision: main
      directories:
        - path: "hosted-clusters/{{ .Values.hubName }}/*"
```

The hosted-cluster values file path stays derived from the generator's
`{{.path.path}}`, which now already includes the hub segment.

## Bootstrap & per-hub onboarding

`bootstrap/bootstrap.yaml` changes from a recursed directory source to a Helm
source that supplies the hub name — the single per-hub input:

```yaml
source:
  repoURL: https://github.com/CCI-MOC/oac-apps.git
  targetRevision: main
  path: applicationsets
  helm:
    parameters:
      - name: hubName
        value: oac-dev-infra      # the only thing that differs per hub
```

The hub name lives *only* in the bootstrap Application, which is already a
manual, once-per-hub `oc apply`. Everything under `main` is identical across
hubs — no branches, no skew.

### Onboarding a new hub (README checklist)

1. `oc apply` the bootstrap with `hubName=<newhub>`.
2. Create `values/hub/<newhub>/` (hub-wide) and per-cluster subdirs as needed —
   only where a chart actually needs an override.
3. Add `hosted-clusters/<newhub>/` if that hub runs hosted clusters.

## Migration (mechanical, behavior-preserving)

The current single hub is `oac-dev-infra`, managing spoke `oac-prod`.

- `git mv values/oac-dev-infra/* → values/hub/oac-dev-infra/local-cluster/`
- `git mv values/oac-prod/* → values/hub/oac-dev-infra/oac-prod/`
- `git mv hosted-clusters/<cluster> → hosted-clusters/oac-dev-infra/<cluster>`
  (for each existing hosted cluster: `oac-prod`, `oac-dev-workload1`)
- **Delete** the 11 empty or `{}`-only value files rather than relocating them
  (they become pure clutter once absence is legal):
  - `values/oac-dev-infra/acm-gitops-integration.yaml`
  - `values/oac-dev-infra/nmstate.yaml`
  - `values/oac-dev-infra/patch-operator.yaml`
  - `values/oac-prod/nfd-operator.yaml`
  - `values/oac-prod/nmstate.yaml`
  - `values/oac-prod/nvidia-gpu-operator.yaml`
  - `values/oac-prod/nvidia-maintenance-operator.yaml`
  - `values/oac-prod/nvidia-network-operator.yaml`
  - `values/oac-prod/rhoai.yaml`
  - `values/oac-prod/serverless-operator.yaml`
  - `values/oac-prod/servicemesh-operator.yaml`

The hub-wide tier (`values/hub/oac-dev-infra/*.yaml`) starts empty; shared
settings are hoisted into it later as an incremental refactor.

## Testing & guardrails

- `helm template applicationsets --set hubName=oac-dev-infra` must render, and
  the generated `valueFiles` paths must match the new tree.
- `helm template applicationsets` with **no** `hubName` must fail (asserts the
  `required` guard).
- Update/extend `scripts/check-values-files.sh` to flag:
  - any value file whose `<component>` segment does not correspond to a real
    chart under `charts/` — catches the silent-typo risk that
    `ignoreMissingValueFiles` introduces (a mistyped filename becomes a no-op
    instead of an error);
  - any reintroduced empty or `{}`-only value file.
- Confirm the chart still builds and existing tests/CI pass after the change.

## Out of scope

- The explicit cross-hub `common/` tier.
- Hoisting shared settings from per-cluster files up into the hub-wide tier.

Both are safe, incremental follow-ups the layout already supports.
