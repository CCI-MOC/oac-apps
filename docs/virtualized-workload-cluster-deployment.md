# Virtualized Workload Cluster Deployment

## Infrastructure Configuration

A virtualized workload cluster requires:

* A hub cluster, where the control plane for the virtualized cluster resides
* A hypervisor cluster, where the VM workers for the virtualized cluster run

This documentation assumes that both the hub cluster and the hypervisor cluster are managed through the [`oac-apps` repository](https://github.com/CCI-MOC/oac-apps), with the hypervisor cluster being a workload cluster deployed by the hub cluster.

###  Hub Cluster

The hub cluster must expose the `virtualization` and `hypervisor` features in `values/<hub>/local-cluster/acm-placements.yaml`:

```
  placements:
    ...
    - name: virtualization-clusters
      matchLabels:
        massopen.cloud/feature-virtualization: "true"
    - name: hypervisor-clusters
      matchLabels:
        massopen.cloud/feature-hypervisor: "true"
    ...
```

It must also define a hypervisor cluster in `values/<hub>/local-cluster/hcp-config.yaml`, specifying an AWS secret containing a kubeconfig that allows the hub cluster to access the hypervisor cluster:

```
  ...

  hypervisorClusters:
    - name: <hypervisor>
      awsSecretKey: cluster/<hub>/hostedcluster/<hypervisor>/kubeadmin
```

### Hypervisor Cluster

The hypervisor cluster must install the `virtualization` and `hypervisor` features by specifying the following `clusterLabels` in `hosted-clusters/<hub>/<hypervisor>/values.yaml`:

```
  ...

  clusterLabels:
    ...
    massopen.cloud/feature-virtualization: "true"
    massopen.cloud/feature-hypervisor: "true"
    ...
```

## Cluster Deployment and Configuration

Virtualized workload cluster configuration and deployment is managed through an ArgoCD instance running on the hub cluster, and the [`oac-apps` repository](https://github.com/CCI-MOC/oac-apps).

Start by updating the hypervisor cluster to define the desired workload cluster in `values/<hub>/<hypervisor>/hypervisor-cluster.yaml`:

```
  hostedClusters:
    - <virtualized-cluster>
```

Next, create the needed virtualized workload cluster configurations:

* `hosted-clusters/<hub>/<virtualized-cluster>/values.yaml`: virtualized workload cluster configuration
   * key differences from non-virtualized workload clusters are:

```
  platform:
    type: KubeVirt
    kubevirt:
      infraKubeConfigSecretName: <hypervisor>-kubeconfig

  services:
    APIServer:
      # Pinned internal LoadBalancer IP: drives the MetalLB pin and the internal
      # API DNS record. Without it the worker VMs' API hostname falls through
      # to the hub router's wildcard, which does not serve :6443, and no node
      # ever joins.
      ipAddress: <unique IP on the hub cluster's network>

  networking:
    clusterNetwork:
      - cidr: <must not overlap the hypervisor's clusterNetwork>
    machineNetwork:
      - cidr: <hypervisor's clusterNetwork CIDR>
    serviceNetwork:
      - cidr: <must not overlap the hypervisor's serviceNetwork>
```

* `values/<hub>/`: virtualized workload cluster component configuration
   * `<component>.yaml`: component configurations applicable hub-wide
   * `<virtualized-cluster>/<component>.yaml`: component configurations applicable to virtualized workload cluster
* `apps/<hub>/`:  additional changes to be applied to the ArgoCD instance running on the hub cluster (which also manages non-virtualized and virtualized workload clusters)

Make the desired customizations, and then submit them as a PR. Once the PR is merged, the ArgoCD instance running on the hub cluster will pick up the changes and deploy/configure the virtualized workload cluster.

Some shared services require additional work prior to configuration. These are detailed here:

* [IDP configuration](idp-configuration.md)
* [Cluster certificates](network-inventory-and-configuration.md#cluster-certificates)
* [Public IPs](network-inventory-and-configuration.md#public-ips)
* [External DNS](network-inventory-and-configuration.md#external-dns)

After the workload cluster is deployed, you may optionally want to [acquire a public IP](network-inventory-and-configuration.md#public-ips) and [expose the cluster's ingress and API IPs to the public internet](network-inventory-and-configuration.md#firewall).

## Example: OAC Dev Workload2 Cluster

* **Infrastructure Configuration**
   * Hub cluster
      * `oac-apps/values/oac-dev-infra/local-cluster/`
         * [`acm-placements.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-dev-infra/local-cluster/acm-placements.yaml)
         * [`hcp-config.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-dev-infra/local-cluster/hcp-config.yaml)
   * Hypervisor cluster
      * `oac-apps` cluster configuration
         * [`hosted-clusters/oac-dev-infra/oac-dev-workload1/values.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/hosted-clusters/oac-dev-infra/oac-dev-workload1/values.yaml)
* **Cluster Deployment and Configuration**
   * `moc-keycloak` IDP configuration
      * [`main.tf`](https://github.com/CCI-MOC/moc-keycloak/blob/main/main.tf) (search for `oac_dev_workload2`)
   * `moc-aws` cluster certificates and external DNS configuration
      * [`main.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/main.tf) (search for `oac_dev_workload2`)
      * [`cert-manager-policies.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/cert-manager-policies.tf) (search for `oac_dev_workload2`)
      * [`hosted-zones.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/hosted-zones.tf) (search for `oac_dev_workload2`)
   * Hypervisor cluster
      * `oac-apps` cluster configuration
         * [`values/oac-dev-infra/oac-dev-workload1/hypervisor-cluster.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-dev-infra/oac-dev-workload1/hypervisor-cluster.yaml)
   * Virtualized workload cluster
      * `oac-apps` cluster configuration
         * [`hosted-clusters/oac-dev-infra/oac-dev-workload2/values.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/hosted-clusters/oac-dev-infra/oac-dev-workload2/values.yaml)
         * [`values/oac-dev-infra/oac-dev-workload2`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-dev-infra/oac-dev-workload2)
            * [`cert-manager.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-dev-infra/oac-dev-workload2/cert-manager.yaml)
            * [`cluster-certificates.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-dev-infra/oac-dev-workload2/cluster-certificates.yaml)
            * [`external-secrets.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-dev-infra/oac-dev-workload2/external-secrets.yaml)
