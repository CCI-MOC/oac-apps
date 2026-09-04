# OAC Architecture and Deployment Workflow

This document details the architecture and deployment workflow for the OAC clusters.

``` mermaid
  graph LR
      subgraph private["Private Network - Requires VPN Access"]
          direction LR
          subgraph infra["Infra Cluster"]
              direction TB
              icp["Infra Control Plane"]
              hcp0["Hosted Control Plane 0"]
              hcp1["Hosted Control Plane 1"]
          end
          subgraph wc0["Workload Cluster 0"]
              direction TB
              w0a["Worker 0"]
              w0b["Worker 1"]
              w0c["Worker 2"]
          end
          subgraph wc1["Workload Cluster 1"]
              direction TB
              w1a["Worker 0"]
              w1b["Worker 1"]
              w1c["Worker 2"]
          end
          hcp0 --> wc0
          hcp1 --> wc1
      end

      ext0((" "))
      ext1((" "))
      ext2((" "))
      ext3((" "))

      wc0 -. "api" .-> ext0
      wc0 -. "ingress" .-> ext1
      wc1 -. "api" .-> ext2
      wc1 -. "ingress" .-> ext3
```

These clusters rely on a number of shared services, described below.

## Shared Services

|       Purpose      |   Tool    | Location                     |
| ------------------ | --------- | ---------------------------- |
| Network            | *Various* | MOC Environment (within VPN) |
| Hardware Inventory | *Various* | MOC Environment (within VPN) |
| Storage            | Pure      | MOC Environment (within VPN) |
| IDP                | Keycloak  | Amazon EKS                   |

* [Network inventory and configuration](network-inventory-and-configuration.md)
* [Hardware inventory and configuration](hardware-inventory-and-configuration.md)
* *Link to Storage (Pure) doc*
   * includes details on how to configure for a cluster; that subsection will be linked from the cluster deployment doc
* *Link to IDP (Keycloak) doc*
   * includes details on how to configure for a cluster; that subsection will be linked from the cluster deployment doc

## Cluster Deployment

Broadly speaking, cluster deployment progresses in two phases:

* Infrastructure Configuration
   * MOC Inventory and Configuration
      * [ansible-switches](https://github.com/CCI-MOC/ansible-switches/): networks, hardware port configuration
      * *??*
   * [open-accelerator-infra](https://github.com/CCI-MOC/open-accelerator-infra/): cluster node inventories, playbooks to configure nodes
* Cluster Deployment and Configuration
   * [oac-apps](https://github.com/CCI-MOC/oac-apps/): cluster configuration

Ideally, the cluster deployment workflow would be confined within these repositories. However the current workflow requires additional steps; these are detailed within the cluster deployment documents linked below.

* [**Infra Cluster**](infra-cluster-deployment.md): runs the control plane for workload clusters; also run gitops tooling responsible for configuring itself and its workload clusters
   * [Infrastructure Configuration](infra-cluster-deployment.md#infrastructure-configuration)
   * [Cluster Deployment and Configuration](infra-cluster-deployment.md#cluster-deployment-and-configuration)
   * [*Example: OAC Prod Infra Cluster*](infra-cluster-deployment.md#example-oac-prod-infra-cluster)

* [**Workload Cluster**](workload-cluster-deployment.md): hosted cluster intended for tenant use; tenant workloads run on dedicated compute nodes and its control plane runs on the infra cluster
   * [Infrastructure Configuration](workload-cluster-deployment.md#infrastructure-configuration)
   * [Cluster Deployment and Configuration](workload-cluster-deployment.md#cluster-deployment-and-configuration)
   * [*Example: OAC Prod Workload0 Cluster*](workload-cluster-deployment.md#example-oac-prod-workload0-cluster)
