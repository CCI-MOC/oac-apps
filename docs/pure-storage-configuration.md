# Pure Storage Configuration

*TBD: Pure storage explanatory text*

## Request Storage for a Cluster

This section assumes that a [storage network has already been reserved](network-inventory-and-configuration.md#network-inventory).

Request Pure storage by submitting a PR to the [`everpure-moc` repository](https://github.com/CCI-MOC/everpure-moc) modifying [`ansible/group_vars/all/realms.yaml`](https://github.com/CCI-MOC/everpure-moc/blob/main/ansible/group_vars/all/realms.yaml) to add a new realm:

```
  - name: <cluster>
    interface_address: <storage subnet .10 address>
    s3_endpoint: storage.massopen.cloud
    subnet_prefix: <storage subnet CIDR>
    subnet_vlan: <storage network VLAN>
    subnet_gateway: <storage subnet .1 address>
    dns_domain: massopen.cloud
    dns_nameservers:
      - <storage subnet .1 address>
```

Once the PR is merged, the sysadmin will run a playbook to provision a Pure storage realm, and to create a secret for the realm and upload it to AWS Secrets Manager with the name `cluster/<cluster>/portworx`.

## Configure Cluster

Start by ensuring that [the storage network is attached to each node in the cluster](hardware-inventory-and-configuration.md#network-configuration). You'll need to identify the storage interface used by each node for the storage network; you can do this by logging into the node and running `ip a`.

Configure a cluster for Pure storage by creating a fork of the [`oac-apps` repository](https://github.com/CCI-MOC/oac-apps) and editing `values/<infra-cluster>/<cluster>/portworx.yaml`:

```
  externalSecret:
    secretStore: aws-secrets-manager
    remoteKey: "cluster/<cluster>/portworx"

  nodes:
    - name: <node0 name>
      interface: <node0 storage interface>
    - name: <node1 name>
      interface: <node1 storage interface>
    - name: <node2 name>
      interface: <node2 storage interface>

  network:
    cidr: "<storage network subnet CIDR>"
    # addresses assigned to pods attached to the storage network; ensure that this will not overlap with IPs assigned to nodes on the storage network
    range:
      start: "<storage network subnet range start>"
      end: "<storage network subnet range end>"
    routes:
      - dst: 10.3.11.50/32
        gw: "<storage network subnet gateway>"
```

Once your changes are ready, submit a PR. When the PR is merged, the ArgoCD instance running on the infra cluster will apply these changes.

## Examples: OAC Prod Infra and Prod Workload0 Storage Configurations

* **OAC Prod Infra**:
   * `everpure-moc`
      * [`ansible/group_vars/all/realms.yaml`](https://github.com/CCI-MOC/moc-dns/blob/main/zonefiles/ocp.massopen.cloud.zone) (search for `oac_prod_infra`)
   * `oac-apps`
      * [`values/oac-prod-infra/local-cluster/portworx.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/local-cluster/portworx.yaml)
* **OAC Prod Workload0**:
   * `everpure-moc`
      * [`ansible/group_vars/all/realms.yaml`](https://github.com/CCI-MOC/moc-dns/blob/main/zonefiles/ocp.massopen.cloud.zone) (search for `oac_prod_workload0`)
   * `oac-apps`
      * [`values/oac-prod-infra/oac-prod-workload0/portworx.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/oac-prod-workload0/portworx.yaml)
