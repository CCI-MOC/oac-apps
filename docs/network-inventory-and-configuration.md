# Network Inventory and Configuration

## Network Inventory

VLANs are tracked in [`vlans.yaml`](https://github.com/CCI-MOC/ansible-switches/blob/main/group_vars/all/vlans.yaml) within the [`ansible-switches` repository](https://github.com/CCI-MOC/ansible-switches/). An entry looks like the following:

```
  - id: 216
    name: OPENACCELERATOR-PRODUCTION
    description: OAC Production Net  10.20.12.0 /23
    fabrics:
      - moc
      - nerc
```

If a VLAN need to be on the firewall, then it also needs to be added to [`host_vars/MOC-CORE-1/interfaces.yaml`](https://github.com/CCI-MOC/ansible-switches/blob/main/host_vars/MOC-CORE-1/interfaces.yaml) and [`host_vars/MOC-CORE-2/interfaces.yaml`](https://github.com/CCI-MOC/ansible-switches/blob/main/host_vars/MOC-CORE-2/interfaces.yaml) under `port-channel 201` and `port-channel 202`.

The process for attaching VLANs to node switchports is described [here](hardware-inventory-and-configuration.md#network-configuration).

## Firewall

Firewall configuration is currently not tracked in any repository, and requires manual updates by MOC sysadmins. Typical requests include:

* Cluster Network
   * configure firewall for subnet
   * allow outbound NAT access
* Storage Network
   * configure routes from the storage network to the Pure API network
* Workload Cluster
   * configure routes from the workload cluster network to the infra cluster network
   * create `allow`rules on the inside interface permitting connections to the external endpoints (to allow OpenShift ingress canary checks to pass)
   * configure HAProxy to expose ingress/API IPs to the public internet (if needed)

Routes on ESI networks are configured within the [`oac-infra` repository]() in [`infra/networks.tf`](https://github.com/CCI-MOC/oac-infra/blob/main/infra/networks.tf).

## Public IPs

Public IPs are tracked in the [`documentation` repository](https://github.com/CCI-MOC/documentation) within the [Public Neu (VLAN 127) subsection of the Kaizen networks document](https://github.com/CCI-MOC/documentation/blob/master/docs/source/networking/kaizen-networks.md#public-neu-vlan-127). To reserve a public IP, simply add it to the documented list with a relevant description.

## Cluster Certificates

Cluster certificates are generated through AWS. In the [`moc-aws` repository](https://github.com/CCI-MOC/moc-aws/), update [`main.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/main.tf) to add an entry for your cluster in `openshift_oidc_clusters`:

```
  openshift_oidc_clusters = {
    ...
    oac_prod_infra = merge(local.openshift_oidc_cluster_defaults, {
      cluster_name            = "oac-prod-infra"
      oidc_bucket_domain_name = aws_s3_bucket.oac_oidc.bucket_regional_domain_name
      cert_manager_policy_arn = module.cert_manager_policy["cert_manager_policy_oac_prod_infra"].policy_arn
      eso_writable_secret_prefixes = [
        "cluster/oac-prod-infra/hostedcluster/",
      ]
    })
    oac_prod_workload0 = merge(local.openshift_oidc_cluster_defaults, {
      cluster_name            = "oac-prod-workload0"
      oidc_bucket_domain_name = aws_s3_bucket.oac_oidc.bucket_regional_domain_name
      cert_manager_policy_arn = module.cert_manager_policy["cert_manager_policy_oac_prod_workload0"].policy_arn
    })
    ...
  }
```

Once your change is merged into `moc-aws`, you will need to checkout the [`oac-apps` repository](https://github.com/CCI-MOC/oac-apps) and run [`bootstrap/setup-oidc.sh`](https://github.com/CCI-MOC/oac-apps/blob/main/bootstrap/setup-oidc.sh).

## DNS

### Internal DNS

Internal DNS configuration is tracked by the [`moc-dns` repository](https://github.com/CCI-MOC/moc-dns/) within a [zonefile](https://github.com/CCI-MOC/moc-dns/tree/main/zonefiles). To make a change, submit a PR; after it is merged, a sysadmin can run a script to apply the changes.

### External DNS

External DNS configuration is tracked by the [`moc-aws` repository](https://github.com/CCI-MOC/moc-aws/) within a few files:

* [`iam-users.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/iam-users.tf): IAM users for configuring external DNS
* [`hosted-zones.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/hosted-zones.tf): hosted zones containing DNS records for a domain
   * use the external hosted control plane load balancer IP for internal services (`oc -n openshift-ingress get svc router-hosted-clusters`)
   * request an external public IP from a sysadmin for external services
* [`cert-manager-policies.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/cert-manager-policies.tf): IAM policies for `cert-manager`
* [`external-dns-policies.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/external-dns-policies.tf): IAM policies for `external-dns`

Infra clusters need to modify all four of these files, while workload clusters only need to modify `cert-manager-polices.tf`. To make a change, submit a PR; after it is merged, the changes will automatically be applied.

#### Configure Cluster

After making the external DNS changes, configure your cluster by submitting a PR to the [`oac-apps` repository](https://github.com/CCI-MOC/oac-apps) adding the file `values/<infra-cluster>/<cluster>/cluster-certificates.yaml`:

```
  clusterDomain: <cluster subdomain specified in cert-manager-policies.tf>
  certificates:
    issuer_name: letsencrypt-prod-dns01
    api:
      enabled: false
```

An infra cluster also needs `values/<infra-cluster>/local-cluster/external-dns-operator.yaml`

```
externaldns:
  - name: aws-route53
    credentials: aws-route53-credentials
    externalSecret:
      remoteKey: cluster/<infra-cluster>/external-dns/aws-route53-credentials
      secretStore: aws-secrets-manager
      secretStoreType: ClusterSecretStore
    domains:
      - filterType: Include
        matchType: Exact
        name: <external hosted control plane services zone name>
      - filterType: Include
        matchType: Exact
        name: <internal hosted control plane services zone name>
    hostnameAnnotation: Allow
    labelFilter:
      matchLabels:
        massopen.cloud/external-dns: "true"
    zones: <zone list>
```

### Examples: OAC Prod Infra and Prod Workload0 DNS Configurations

* **OAC Prod Infra**:
   * `moc-dns`
      * [`ocp.massopen.cloud.zone`](https://github.com/CCI-MOC/moc-dns/blob/main/zonefiles/ocp.massopen.cloud.zone) (search for `infra.oac.ocp.massopen.cloud`)
   * `moc-aws`
      * [`iam-users.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/iam-users.tf) (search for `oac-massopen-cloud` and `oac-prod-external-dns`)
      * [`hosted-zones.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/hosted-zones.tf) (search for `oac.massopen.cloud`)
      * [`cert-manager-policies.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/cert-manager-policies.tf) (search for `oac_prod_infra`)
      * [`external-dns-policies.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/external-dns-policies.tf) (search for `oac_massopen`)
   * `oac-apps`
      * [`values/oac-prod-infra/local-cluster/cluster-certificates.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/local-cluster/cluster-certificates.yaml)
      * [`values/oac-prod-infra/local-cluster/external-dns-operator.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/local-cluster/external-dns-operator.yaml)
* **OAC Prod Workload0**: [`values/oac-prod-workload0/portworx.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/oac-prod-workload0/portworx.yaml)
   * `moc-aws`
      * [`cert-manager-policies.tf`](https://github.com/CCI-MOC/moc-aws/blob/main/cert-manager-policies.tf) (search for `oac_prod_workload0`)
   * `oac-apps`
      * [`values/oac-prod-infra/oac-prod-workload0/cluster-certificates.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/oac-prod-workload0/cluster-certificates.yaml)
