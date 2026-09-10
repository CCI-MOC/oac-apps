# Infra Cluster Deployment

## Infrastructure Configuration

We have deployed the infra cluster in two hardware configurations:

* **Compact**
   * Three nodes that each serve as both control plane and worker
   * Suitable for dev environments to minimize the amount of hardware required
   * e.g. `oac-dev-infra` uses three `FC830s`
* **Standard**
   * Three nodes dedicated as control plane; three nodes dedicated as workers
   * Suitable for prod environments to maximize the resources available for hosted control planes
   * e.g. `oac-prod-infra` uses three `FC430s` as control plane nodes and three `FC830s` as workers

After identifying the nodes that will be used for the cluster, the configuration steps are as follows:

* **Networking**
   * An infra cluster requires a cluster network and a storage network
      * [Add cluster and storage networks to the MOC inventory](network-inventory-and-configuration.md#network-inventory)
      * [Attach these networks to each node](hardware-inventory-and-configuration.md#network-configuration)
   * Perform the [appropriate firewall configurations](network-inventory-and-configuration.md#firewall) for the cluster and storage networks
* **`open-accelerator-infra` inventory**
   * Modify [`inventory/00hosts.yaml`](https://github.com/CCI-MOC/open-accelerator-infra/blob/main/infra/inventory/00hosts.yaml) to add the new infra cluster and its associated nodes
* **Additional node information**
   * Obtain additional information from the nodes by [booting the node](hardware-inventory-and-configuration.md#boot-configuration) with the discovery image `http://10.2.0.82/boot/discovery.iso`
      * Once booted, discovery information can be accessed at `http://<node-ip-on-cluster-network>/index.txt`
      * This information will be required during cluster deployment

## Cluster Deployment

Start by creating a cluster discovery image. The current procedure for doing so is as follows:

* Check out the [`open-accelerator` branch of the `ai-ivp` repository](https://github.com/CCI-MOC/ai-ivp/tree/open-accelerator)
* Add an entry for the new cluster in [`playbooks/inventory.yml`](https://github.com/CCI-MOC/ai-ivp/blob/open-accelerator/playbooks/inventory.yml)
* Create a directory for the new cluster in `playbooks/credentials/<cluster>/`
   * Create a new keypair
      * Copy the public key here
      * Add the public and private key as a secret in AWS Secrets Manager with the name `cluster/<cluster>/sshkey` and properties `publicKey` and `privateKey`
   * Obtain [your pull secret](https://console.redhat.com/openshift/install/pull-secret) and place it here
* Create a directory for the new cluster in [`playbooks/group_vars/<infra-cluster>/`](https://github.com/CCI-MOC/ai-ivp/tree/open-accelerator/playbooks/group_vars)
   * Add a `secrets.yml` file that specifies the `pull_secret`
   * Copy a `vars.yml` file from an existing cluster, and update it to specify the desired hardware and networks (information obtained from booting the discovery image is required)
      * The values for `api_ip` and `ingress_ip` should be on the cluster subnet
   * [Update internal DNS](network-inventory-and-configuration.md#internal-dns) with these entries:

```
          api.<cluster_domain_name>.<base_domain_name>.     300 IN A     <api_ip>
          api-int.<cluster_domain_name>.<base_domain_name>.     300 IN A     <api_ip>
          *.apps.<cluster_domain_name>.<base_domain_name>.     300 IN A     <ingress_ip>
```

* Run `ansible-playbook playbooks/create_agent_install_media.yaml -e "cluster_name=<infra-cluster>"`
   * The [templates used](https://github.com/CCI-MOC/ai-ivp/tree/open-accelerator/playbooks/roles/create_agent_install_media/templates) are hardcoded for a compact cluster; however these templates are easily modified for a standard cluster.
* The playbook generates a `kubeadmin` password, kubeconfig, and cluster discovery image
   * Record the `kubeadmin` password and kubeconfig as a secret in AWS Secrets Manager with the name `cluster/<infra-cluster>/kubeadmin` and properties `password` and `kubeconfig`
   * Rename the cluster discovery image to `<infra-cluster>-discovery.iso` and copy it to the `/srv/boot/` directory of the bastion host

Afterwards, update [`inventory/00hosts.yaml`](https://github.com/CCI-MOC/open-accelerator-infra/blob/main/infra/inventory/00hosts.yaml) to specify the discovery image `http://10.2.0.82/boot/<infra-cluster>-discovery.iso` and [boot the nodes](hardware-inventory-and-configuration.md#boot-configuration).

## Cluster Configuration

Infra cluster configuration is managed through ArgoCD and the [`oac-apps` repository](https://github.com/CCI-MOC/oac-apps). After deploying an infra cluster, fork the repository and run the following command (using the kubeconfig of the infra cluster):

```
  $ helm template bootstrap ./bootstrap --set hubName=<infra-cluster> | oc apply -f -
```

This will install an ArgoCD instance configured to run off Helm charts in `oac-apps` that are associated with `<infra-cluster>`. ArgoCD will look at the following files and directories:

* `hosted-clusters/<infra-cluster>/values.yaml`: default values for hosted clusters deployed by this infra cluster
* `values/<infra-cluster>/`
   * `<component>.yaml`: default values for this component on hosted clusters deployed by this infra cluster
   * `local-cluster/<component>.yaml`: values for this component on this infra cluster
* `apps/<infra-cluster>/`: manifests to be applied directly to the ArgoCD instance on this infra cluster

Make the desired customizations, and then submit them as a PR. Once the PR is merged, the ArgoCD instance running on the infra cluster will pick up the changes and configure the infra cluster.

Some shared services require additional work prior to configuration. These are detailed here:

* [Pure storage configuration](pure-storage-configuration.md)
* [External DNS](network-inventory-and-configuration.md#external-dns)
* keycloak (*TBD*)
* AWS setup (*TBD*)
* ??

## Example: OAC Prod Infra Cluster

* **Infrastructure Configuration**
   * VLANs
      * [Cluster network](https://github.com/CCI-MOC/ansible-switches/blob/main/group_vars/all/vlans.yaml#L82-L87)
      * [Storage network](https://github.com/CCI-MOC/ansible-switches/blob/main/group_vars/all/vlans.yaml#L2038-L2044)
   * Network configuration
      * [`MOC-R4PAC10-SW-TORS-A`](https://github.com/CCI-MOC/ansible-switches/blob/main/host_vars/MOC-R4PAC10-SW-TORS-A/interfaces.yaml) (search for `OAC Prod Infra`)
      * [`MOC-R4PAC10-SW-TORS-B`](https://github.com/CCI-MOC/ansible-switches/blob/main/host_vars/MOC-R4PAC10-SW-TORS-B/interfaces.yaml) (search for `OAC Prod Infra`)
      * Additional nodes are either manually configured, or managed through ESI
   * `open-accelerator-infra` hosts inventory
      * [`00hosts.yaml`](https://github.com/CCI-MOC/open-accelerator-infra/blob/main/infra/inventory/00hosts.yaml#L61-L106)
   * `moc-dns` Internal DNS
      * [`ocp.massopen.cloud.zone`](https://github.com/CCI-MOC/moc-dns/blob/main/zonefiles/ocp.massopen.cloud.zone) (search for `infra.oac.ocp.massopen.cloud`)
* **Cluster Deployment**
   * `ai-ivp`
      * changes are yet to be merged
      * [`playbooks/inventory.yml`](https://github.com/tzumainn/ai-ivp/blob/open-accelerator/playbooks/inventory.yml#L19-L22)
      * [`playbooks/group_vars/oac-prod-infra/vars.yml`](https://github.com/tzumainn/ai-ivp/blob/open-accelerator/playbooks/group_vars/oac-prod-infra/vars.yml)
      * [modifications to `playbooks/roles/create_agent_install_media/templates/`](https://github.com/tzumainn/ai-ivp/tree/open-accelerator/playbooks/roles/create_agent_install_media/templates) for deploying a standard cluster
* **Cluster Configuration**
   * `everpure-moc` Pure storage configuration
      * [`ansible/group_vars/all/realms.yaml`](https://github.com/CCI-MOC/moc-dns/blob/main/zonefiles/ocp.massopen.cloud.zone) (search for `oac_prod_infra`)
   * `moc-aws` external DNS configuration
      * [`iam-users.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/iam-users.tf) (search for `oac-massopen-cloud` and `oac-prod-external-dns`)
      * [`hosted-zones.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/hosted-zones.tf) (search for `oac.massopen.cloud`)
      * [`cert-manager-policies.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/cert-manager-policies.tf) (search for `oac_prod_infra`)
      * [`external-dns-policies.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/external-dns-policies.tf) (search for `oac_massopen`)
   * `oac-apps` cluster configuration
      * `hosted-clusters/oac-prod-infra/values.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/hosted-clusters/oac-prod-infra/values.yaml)
      * `values/oac-prod-infra/`
         * [`hcp-config.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/hcp-config.yaml)
         * [`local-cluster/`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/local-cluster)
            * [`portworx.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/local-cluster/portworx.yaml)
            * [`cluster-certificates.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/local-cluster/cluster-certificates.yaml)
            * [`external-dns-operator.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/local-cluster/external-dns-operator.yaml)
            * additional component configuration
      * `apps/oac-prod-infra/`
         * [`keycloak-oauth.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/apps/oac-prod-infra/keycloak-oauth.yaml)
