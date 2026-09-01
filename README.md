# oac-apps

ArgoCD-managed configuration for the OAC OpenShift clusters. A bootstrap Application discovers ApplicationSets, which deploy Helm charts to the hub and managed clusters using ACM placements.

## Requirements

If you are working with this repository you will need:

- [helm](https://helm.sh)

You may want:

- [ct](https://github.com/helm/chart-testing) the chart testing tool
- [kustomize](https://kustomize.io/) because everyone loves kustomize
- [chainsaw](https://github.com/kyverno/chainsaw) for writing declarative tests of kubernetes

## Repository structure

| Directory                            | Description                                                      |
| ------------------------------------ | ---------------------------------------------------------------- |
| `bootstrap/`                         | One-time setup: bootstrap Application and OIDC scripts           |
| `applicationsets/`                   | ArgoCD ApplicationSets (Helm chart rendered with `hubName`)      |
| `applicationsets/templates/hub/`     | ApplicationSets targeting the hub cluster                        |
| `applicationsets/templates/managed/` | ApplicationSets targeting managed (spoke) clusters via ACM       |
| `charts/`                            | Helm charts, one per component                                   |
| `charts/operator-library/`           | Shared library chart providing helpers for operator installation |
| `values/`                            | Per-hub, per-cluster Helm values overrides (optional)            |
| `values/<hub>/`                      | Hub-wide defaults, applied to every cluster in that hub          |
| `values/<hub>/<cluster>/`            | Per-cluster overrides (`local-cluster` = the hub itself)         |
| `apps/`                              | Drop-in raw ArgoCD manifests, applied per hub (see below)        |
| `apps/<hub>/`                        | Manifests applied verbatim to that hub's ArgoCD                  |
| `hosted-clusters/`                   | HyperShift hosted cluster definitions                            |
| `scripts/`                           | Operational and CI scripts                                       |
| `docs/`                              | Documentation                                                    |

## How it works

`bootstrap/` is a small Helm chart that renders an ArgoCD Application pointing at `applicationsets/`. Deploy it per hub with `helm template bootstrap ./bootstrap --set hubName=<hub> | oc apply -f -`; `hubName` has no default, so an unparameterized render fails closed. The hub name flows through to the bootstrap Application's `hubName` parameter, and ArgoCD discovers all ApplicationSets under that directory:

- `applicationsets/templates/hub/hub-components.yaml` deploys charts to the hub cluster. Each Application lists a hub-wide values file (`values/<hub>/<component>.yaml`) then a per-cluster file (`values/<hub>/local-cluster/<component>.yaml`), both optional via `ignoreMissingValueFiles`.
- `applicationsets/templates/hub/hosted-clusters.yaml` uses a Git directory generator to deploy the `hosted-cluster` chart once per directory under `hosted-clusters/<hub>/`, creating a HyperShift HostedCluster on the hub for each. Its hub-side prerequisites (the `clusters` namespace, pull secret, SSH key, and IngressController) are installed by the `hcp-config` chart.
- `applicationsets/templates/managed/*.yaml` use ACM Placements to deploy charts to spoke clusters. Each Application lists a hub-wide values file then a per-cluster file, both optional via `ignoreMissingValueFiles`.
- `applicationsets/templates/hub/cluster-apps.yaml` is an "app of apps" that applies any manifests found under `apps/<hub>/` verbatim (see [Per-hub drop-in apps](#per-hub-drop-in-apps)).

Placements are defined in two charts:

- `charts/acm-gitops-integration` defines the `all-managed-clusters` Placement used by the GitOpsCluster resource to register managed clusters with ArgoCD.
- `charts/acm-placements` defines workload-targeting Placements (e.g., `gpu-clusters`, `portworx-clusters`) referenced by the managed-cluster ApplicationSets.

### Ordering between components

There is no cross-component ordering. Each component is a
separate ArgoCD Application created directly by the ApplicationSet controller,
and every Application syncs independently and in parallel.

Components converge via retry and self-heal: an Application whose
dependency is not yet ready (e.g. a CustomResource whose operator CRDs do not
exist yet) fails, backs off, and is retried until it succeeds. Hard ordering
that genuinely matters (namespaces before namespaced resources, CRDs before
CRs) is expressed with resource-level sync-waves *inside* each chart, where the
annotation does work.

## Charts

Each chart under `charts/` installs a single component. Many use the `operator-library` library chart to install an OLM operator subscription. Charts with required values include `ci/test-values.yaml` for use with `ct lint`.

## Adding a new component

1. Create a chart under `charts/`.
2. Add the component to the appropriate ApplicationSet template under
   `applicationsets/templates/`.
3. Only if the chart needs overrides, add `values/<hub>/<component>.yaml`
   (hub-wide) and/or `values/<hub>/<cluster>/<component>.yaml` (per-cluster).
   Charts with no overrides need no values file at all.

## Per-hub drop-in apps

The common `hub-components` set deploys the same components to every hub. When
you want a component (or any resource) on **one specific cluster** and not
others, drop a raw ArgoCD manifest into `apps/<hub>/` instead of adding it to
the shared set.

The `cluster-apps` Application (`applicationsets/templates/hub/cluster-apps.yaml`)
applies everything under `apps/<hub>/` verbatim, so a file there is a manifest
ArgoCD applies as-is — typically an `Application`, but any manifest works.

- Files can be Applications targeting the hub itself **or** any managed/hosted
  cluster: the manifest's own `spec.destination` is what routes it. Subdirectories
  under `apps/<hub>/` are for your own organization only — nothing consumes their
  names.
- No scaffolding is needed to start. `cluster-apps` watches the always-present
  `apps/` root scoped to `<hub>/*`, so a hub with no drop-in apps renders zero
  resources and stays healthy; the first file in `apps/<hub>/` lights it up.
- For an app-of-apps child that should clean up its own resources when its file
  is removed, add the `resources-finalizer.argocd.argoproj.io` finalizer (see
  `apps/oac-dev-infra/github-oauth.yaml`).

`apps/oac-dev-infra/github-oauth.yaml` and `github-group-sync.yaml` are worked
examples: both were once in the common `hub-components` set but are only
configured for `oac-dev-infra`, so they now live as per-hub drop-ins.

## Onboarding a new hub

1. Render and apply the bootstrap Application with the new hub's name:
   `helm template bootstrap ./bootstrap --set hubName=<newhub> | oc apply -f -`.
2. Create `values/<newhub>/` and per-cluster subdirectories only where a
   chart needs an override.
3. Add `hosted-clusters/<newhub>/` if that hub runs HyperShift hosted clusters.

No `apps/<newhub>/` directory is needed up front; create it only when you have a
per-hub drop-in app for that hub.

Everything on `main` is shared across hubs; the only per-hub input is the
`hubName` parameter in the bootstrap Application.
