# Hardware Inventory and Configuration

## Hardware Inventory

The MOC is currently in a transitional state when it comes to its hardware inventory. Previously, the bulk of the hardware was inventoried in ESI. ESI is now in the process of being decommissioned - *without* a new hardware inventory in place. As a result, there is a segment of OAC hardware that is essentially non-inventoried. OAC uses a combination of this non-inventoried hardware and ESI nodes.

|    Inventory    |  Resource Class  |                                                               |
| --------------- | ---------------- | ------------------------------------------------------------- |
| Non-Inventoried | `R4PAC10` Nodes  | `FC430s` and `FC830s` taken out of ESI                        |
| Non-Inventoried | `R440s`          | new hardware currently unused due to initial misconfiguration |
| ESI             | `H100s`          |                                                               |
| ESI             | `A100s`          |                                                               |
| ESI             | `FC430s`         | used by OAC dev environment                                   |
| ESI             | `FC830s`         | used by OAC dev environment                                   |

In the future, we would like to unify our hardware inventory within a new RHOSO18 environment. This RHOSO18 inventory would feed into an Netbox instance.

## Hardware Configuration

The steps required to perform hardware configuration varies, due to the mix of non-inventoried and ESI hardware.

### Network Configuration

This section assumes that a [network has already been reserved](network-inventory-and-configuration.md#network-inventory).

Currently network configuration is accomplished through a combination of ESI APIs, `CCI-MOC` repositories (which record configurations and applies them through playbooks), and direct sysadmin requests. The `CCI-MOC` repositories used are: 

* [`ansible-switches`](https://github.com/CCI-MOC/ansible-switches/): manages VLANs and node port configuration
* *TBD*

#### Non-Inventoried

Nodes on a Dell switch should have their networks configured by modifying the appropriate interface within [`host_vars`](https://github.com/CCI-MOC/ansible-switches/tree/main/host_vars) (since these nodes are currently un-inventoried, the easiest way locate an interface for a node is to search the [ESI manifests](https://github.com/CCI-MOC/esi-pilot/tree/main/nodes)). For example [`MOC-R4PAC10-SW-TORS-A/interfaces.yaml`](https://github.com/CCI-MOC/ansible-switches/blob/main/host_vars/MOC-R4PAC10-SW-TORS-A/interfaces.yaml) has the following entry:

```
  twentyFiveGigE 1/6/4:
    description: "U25-S3-P1 OAC Prod 1"
    state: "up"
    mtu: 9216
    portmode: "access"
    untagged: 216
    stp:
      edgeport: true
      bpduguard: true
```

Once changes are merged to the `ansible-switches` repository, a sysadmin runs a playbook to apply these changes.

Nodes that are not on a Dell switch - essentially, all GPU nodes - do not maintain their networks through `ansible-switches`. You must contact a sysadmin to configure the networking for these nodes.

#### ESI

Nodes managed through ESI should have their networking configured through ESI as well. The first step is to create a network corresponding to your VLAN:

```
  $ openstack network create --provider-network-type vlan --provider-segment 216 --mtu 1500 --share prod-workload0
```

Afterwards, you can use ESI CLI commands to configure networking:

```
  $ openstack esi node network attach --network prod-workload0 MOC-R4PAC21U03-S3   # attach network prod-workload0 to node MOC-R4PAC21U03-S3
  $ openstack esi node network list --node MOC-R4PAC21U03-S3                       # view current network configuration for node MOC-R4PAC21U03-S3
  $ openstack esi node network detach --all MOC-R4PAC21U03-S3                      # detach all networks from node MOC-R4PAC21U03-S3
```

Note that `A100` nodes in ESI only show one NIC. A second NIC has been made available for `A100s` used by OAC; however this second NIC can only be configured by contacting a sysadmin.

### Boot Configuration

We currently boot the bulk of our hardware through the [`boot-image.yaml`](https://github.com/CCI-MOC/open-accelerator-infra/blob/main/infra/boot-image.yaml) playbook in the [`open-acclerator-infra` repository](https://github.com/CCI-MOC/open-accelerator-infra). This playbook uses the virtual media support of the BMC to attach an http-hosted disk image as a virtual CD-ROM device, and configures the node to perform a one-time boot on that device. Running this playbook requires your hardware to be added to [`inventory/00hosts.yaml`](https://github.com/CCI-MOC/open-accelerator-infra/blob/main/infra/inventory/00hosts.yaml) in the [open-accelerator-infra](https://github.com/CCI-MOC/open-accelerator-infra) repository; the entry for the `prod-workload0` cluster is as follows:

```
        oac_prod_workload0:
          vars:
            cluster: oac-prod-workload0
            bmc_type: idrac
          children:
            oac_prod_workload0_compute:
              vars:
                boot_image_url: "http://10.2.0.82/boot/prod-workload0-agent-discovery.iso"
                bm_management: bmc
              hosts:
                oac-prod-workload0-compute-0:
                  node_name: MOC-R4PAC10U29-S3
                  bmc_addr: 10.2.13.152
                  mac_addr: 24:8a:07:1e:85:f4
                  resource_class: fc830
                oac-prod-workload0-compute-1:
                  node_name: MOC-R4PAC10U27-S3
                  bmc_addr: 10.2.13.142
                  mac_addr: 24:8a:07:1e:85:a4
                  resource_class: fc830
                oac-prod-workload0-compute-2:
                  node_name: MOC-R4PAC10U25-S3
                  bmc_addr: 10.2.13.132
                  mac_addr: 24:8a:07:1e:34:a6
                  resource_class: fc830
            oac_prod_workload0_gpu:
              vars:
                boot_image_url: "http://10.2.0.82/boot/prod-workload0-agent-discovery.iso"
                bm_management: openstack
                bmc_type: lenovo
              hosts:
                oac-prod-workload0-gpu-0:
                  node_name: MOC-R4PCC02U10
                  bmc_addr: 10.2.19.110
                oac-prod-workload0-gpu-1:
                  node_name: MOC-R4PCC04U09
                  bmc_addr: 10.2.20.109
                oac-prod-workload0-gpu-2:
                  node_name: MOC-R4PCC04U11
                  bmc_addr: 10.2.20.111
```

Note that nodes managed via direct BMC access (`bm_management: bmc`) have different attributes than those managed with `OpenStack` (`bm_management: openstack`).

Afterwards, you can boot the desired nodes. For example, the following command boots nodes in the `oac_prod_workload0_gpu` group:

```
  $ ansible-playbook boot-image.yaml -l oac_prod_workload0_gpu
```

Due to various quirks, `A100s` currently cannot be booted in this manner, and should be [deployed through ESI](https://esi.readthedocs.io/en/latest/usage/openshift.html#deploy) instead. If this hardware class proves to be part of OAC's future plans, we will do work to integrate them with the `boot-image.yaml` playbook.

We plan to unify our hardware configuration around RHOSO18 and the OpenStack Ironic and Neutron APIs.