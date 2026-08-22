# oac-apps

ArgoCD-managed configuration for the OAC OpenShift clusters. A bootstrap Application discovers ApplicationSets, which deploy Helm charts to the hub and managed clusters using ACM placements.

## Repository structure

```
bootstrap/              One-time setup: bootstrap Application and OIDC scripts
applicationsets/        ArgoCD ApplicationSets (discovered by bootstrap)
  hub/                  ApplicationSets targeting the hub cluster
  managed/              ApplicationSets targeting managed (spoke) clusters via ACM
charts/                 Helm charts, one per component
  operator-library/     Shared library chart providing helpers for operator installation
values/                 Per-cluster Helm values overrides
  oac-dev-infra/        Values for the hub/infrastructure cluster
  oac-prod/             Values for the oac-prod managed cluster
hosted-clusters/        HyperShift hosted cluster definitions
scripts/                Operational and CI scripts
docs/                   Documentation
```

## How it works

`bootstrap/bootstrap.yaml` creates an ArgoCD Application pointing at `applicationsets/`. ArgoCD discovers all ApplicationSets under that directory:

- `applicationsets/hub/hub-components.yaml` deploys charts to the hub cluster, using values from `values/oac-dev-infra/`.
- `applicationsets/managed/*.yaml` use ACM Placements to deploy charts to spoke clusters, using values from `values/<cluster-name>/`.

Placements are defined in two charts:

- `charts/acm-gitops-integration` defines the `all-managed-clusters` Placement used by the GitOpsCluster resource to register managed clusters with ArgoCD.
- `charts/acm-placements` defines workload-targeting Placements (e.g., `gpu-clusters`, `portworx-clusters`) referenced by the managed-cluster ApplicationSets.

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
