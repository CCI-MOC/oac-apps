# oac-apps

ArgoCD-managed configuration for the OAC OpenShift clusters. A bootstrap Application discovers ApplicationSets, which deploy Helm charts to the hub and managed clusters using ACM placements.

## Requirements

If you are working with this repository you will need:

- [helm](https://helm.sh)

You may want:

- [ct](https://github.com/helm/chart-testing) the chart testing tool
- [kustomize](https://kustomize.io/) because everyone loves kustomize
- [chainsaw](github.com/kyverno/chainsaw) for writing declarative tests of kubernetes

## Repository structure

| Directory                  | Description                                                      |
| -------------------------- | ---------------------------------------------------------------- |
| `bootstrap/`               | One-time setup: bootstrap Application and OIDC scripts           |
| `applicationsets/`         | ArgoCD ApplicationSets (discovered by bootstrap)                 |
| `applicationsets/hub/`     | ApplicationSets targeting the hub cluster                        |
| `applicationsets/managed/` | ApplicationSets targeting managed (spoke) clusters via ACM       |
| `charts/`                  | Helm charts, one per component                                   |
| `charts/operator-library/` | Shared library chart providing helpers for operator installation |
| `values/`                  | Per-cluster Helm values overrides                                |
| `values/oac-dev-infra/`    | Values for the hub/infrastructure cluster                        |
| `values/oac-prod/`         | Values for the oac-prod managed cluster                          |
| `hosted-clusters/`         | HyperShift hosted cluster definitions                            |
| `scripts/`                 | Operational and CI scripts                                       |
| `docs/`                    | Documentation                                                    |

## How it works

`bootstrap/bootstrap.yaml` creates an ArgoCD Application pointing at `applicationsets/`. ArgoCD discovers all ApplicationSets under that directory:

- `applicationsets/hub/hub-components.yaml` deploys charts to the hub cluster, using values from `values/oac-dev-infra/`.
- `applicationsets/hub/hosted-clusters.yaml` uses a Git directory generator to deploy the `hosted-cluster` chart once per directory under `hosted-clusters/`, creating a HyperShift HostedCluster on the hub for each. Its hub-side prerequisites (the `clusters` namespace, pull secret, SSH key, and IngressController) are installed by the `hcp-config` chart.
- `applicationsets/managed/*.yaml` use ACM Placements to deploy charts to spoke clusters, using values from `values/<cluster-name>/`.

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
2. Add a values file `values/<cluster>/<chart>.yaml` for each target cluster.
3. Add the component to the appropriate ApplicationSet in `applicationsets/`.

## Things not currently managed

### Node topology labels

Via https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/hosted_control_planes/deploying-hosted-control-planes#hcp-bm-prepare_hcp-deploy-bm:

> Add the topology.kubernetes.io/zone label to your bare-metal hosts on your
> management cluster. Ensure that each host has a unique value for
> topology.kubernetes.io/zone. Otherwise, all of the control plane pods are
> scheduled on a single node, causing a single point of failure.
