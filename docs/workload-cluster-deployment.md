# Workload Cluster Deployment

## Infrastructure Configuration

A workload cluster only needs nodes for additional worker nodes (since its control plane runs on its associated infra cluster). The number of needed worker nodes is not fixed, and is dependent on the desired capacity of the workload cluster.

* **Networking**
   * A workload cluster requires a cluster network and a storage network
      * [Add cluster and storage networks to the MOC inventory](network-inventory-and-configuration.md#network-inventory)
      * [Attach these networks to each node](hardware-inventory-and-configuration.md#network-configuration)
* **`open-accelerator-infra` inventory**
   * Modify [`inventory/00hosts.yaml`](https://github.com/CCI-MOC/open-accelerator-infra/blob/main/infra/inventory/00hosts.yaml) to add the new workload cluster and its associated nodes
* **Add nodes as agents to the infra cluster**
   * Agent discovery image
      * Obtain the agent discovery image from the infra cluster: `oc get infraenv -n hardware-inventory hardware-inventory -o jsonpath='{.status.isoDownloadURL}'`
      * Rename the agent discovery image to `<cluster>-agent-discovery.iso` and copy it to the `/srv/boot/` directory of the bastion host
   * [Boot the nodes](hardware-inventory-and-configuration.md#boot-configuration) with the discovery image `http://10.2.0.82/boot/<cluster>-agent-discovery.iso`
   * These nodes should eventually appear as agents in the infra cluster: `oc get agents -n hardware-inventory`
   * Label these agents with additional metadata: `ansible-playbook update-agents.yaml -l <cluster>`

## Cluster Deployment and Configuration

Workload cluster configuration and deployment is managed through an ArgoCD instance running on the infra cluster, and the [`oac-apps` repository](https://github.com/CCI-MOC/oac-apps).

* `hosted-clusters/<infra-cluster>/<cluster>/values.yaml`: workload cluster configuration
* `values/<infra-cluster>/`: workload cluster component configuration
   * `<component>.yaml`: component configurations applicable hub-wide
   * `<cluster>/<component>.yaml`: component configurations applicable to workload cluster
* `apps/<infra-cluster>/`:  additional changes to be applied to the ArgoCD instance running on the infra cluster (which also manages workload clusters)

Make the desired customizations, and then submit them as a PR. Once the PR is merged, the ArgoCD instance running on the infra cluster will pick up the changes and deploy/configure the workload cluster.

Some shared services require additional work prior to configuration. These are detailed here:

* [Pure storage configuration](pure-storage-configuration.md)
* [IDP configuration](idp-configuration.md)
* observability (*TBD*)
* additional networking (firewall, dns, etc) (*TBD*)
* ??

## Example: OAC Prod Workload0 Cluster

* **Infrastructure Configuration**
   * VLANs
      * [Cluster network](https://github.com/CCI-MOC/ansible-switches/blob/main/group_vars/all/vlans.yaml#L99-L104)
      * [Storage network](https://github.com/CCI-MOC/ansible-switches/blob/main/group_vars/all/vlans.yaml#L2052-L2058)
   * Network configuration
      * [`MOC-R4PAC10-SW-TORS-A`](https://github.com/CCI-MOC/ansible-switches/blob/main/host_vars/MOC-R4PAC10-SW-TORS-A/interfaces.yaml) (search for `OAC Prod`)
      * [`MOC-R4PAC10-SW-TORS-B`](https://github.com/CCI-MOC/ansible-switches/blob/main/host_vars/MOC-R4PAC10-SW-TORS-B/interfaces.yaml) (search for `OAC Prod`)
      * Additional nodes are either manually configured, or managed through ESI
* **Cluster Deployment and Configuration**
   * `open-accelerator-infra` hosts inventory
      * [`00hosts.yaml`](https://github.com/CCI-MOC/open-accelerator-infra/blob/main/infra/inventory/00hosts.yaml#L107-L146)
   * `moc-keycloak` IDP configuration
      * [`main.tf`](https://github.com/CCI-MOC/moc-keycloak/blob/main/main.tf) (search for `oac_prod_workload0`)
   * `oac-apps` cluster configuration
      * `hosted-clusters/oac-prod-infra/`
         * [`values.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/hosted-clusters/oac-prod-workload0/values.yaml)
         * [`oac-prod-workload0/values.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/hosted-clusters/oac-prod-infra/oac-prod-workload0/values.yaml)
      * `values/oac-prod-infra/`
         * [`hcp-config.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/hcp-config.yaml)
         * [`oac-prod-workload0/`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/oac-prod-workload0)
            * [`portworx.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/oac-prod-workload0/portworx.yaml)
            * additional component configuration
