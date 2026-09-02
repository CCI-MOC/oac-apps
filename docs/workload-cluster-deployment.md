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

Workload cluster deployment is managed through the [`oac-apps` repository](https://github.com/CCI-MOC/oac-apps).

* Details (*TBD*)

### Post Deployment Configuration

* `oac-apps` update (*TBD*)
   * storage
* operators (*TBD*)
   * observability (*TBD*)
* keycloak (*TBD*)
* storage (*TBD*)
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
   * `oac-apps` cluster configuration
      * [`values.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/hosted-clusters/oac-prod-infra/oac-prod-workload0/values.yaml)