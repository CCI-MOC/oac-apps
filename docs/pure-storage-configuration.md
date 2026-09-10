# Pure Storage Configuration

*TBD: Pure storage explanatory text*

## Request Storage for a Cluster

This section assumes that a [storage network has already been reserved](network-inventory-and-configuration.md#network-inventory).

Request Pure storage from a sysadmin, providing them the following information:

* storage network
* cluster name

The sysadmin will:

* Provision a Pure storage realm
* Create a secret for the realm and upload it to AWS Secrets Manager with the name `cluster/<cluster>/portworx`.

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

* **OAC Prod Infra**: [`values/local-cluster/portworx.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/local-cluster/portworx.yaml)
* **OAC Prod Workload0**: [`values/oac-prod-workload0/portworx.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/oac-prod-workload0/portworx.yaml)
