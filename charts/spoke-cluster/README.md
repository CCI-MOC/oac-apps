# Spoke Cluster

Helm chart for deploying a new OpenShift spoke cluster via the Assisted Installer on a hub cluster running multicluster engine (MCE).

## Create a New Cluster

1. Create a values file for the cluster (e.g. `values/oac-dev-infra/spoke-cluster-<cluster-name>.yaml`):

   | Value | Description |
   |-------|-------------|
   | `clusterName` | Resource names, labels, and refs (e.g. `jetty`) |
   | `namespace` | Kubernetes namespace (e.g. `clusters-jetty`) |
   | `baseDomain` | DNS base domain for the cluster |
   | `release.name` | ClusterImageSet name (e.g. `openshift-v4.22.14`) |
   | `release.image` | OCP release image (e.g. `quay.io/openshift-release-dev/ocp-release:4.x.x-multi`) |
   | `apiVIP` | Virtual IP for the API server (unused IP on the machine network) |
   | `ingressVIP` | Virtual IP for ingress (unused IP on the machine network) |
   | `networking.clusterNetwork.cidr` | Internal pod network CIDR (default: `10.128.0.0/14`) |
   | `networking.clusterNetwork.hostPrefix` | Per-node pod subnet size (default: `23`) |
   | `networking.serviceNetwork.cidr` | Internal service network CIDR (default: `172.30.0.0/16`) |
   | `networking.machineNetwork.cidr` | Bare metal network CIDR that nodes are physically on |
   | `provisionRequirements.controlPlaneAgents` | Number of control plane nodes (default: `3`) |
   | `provisionRequirements.workerAgents` | Number of worker nodes (default: `0`) |
   | `fips` | Set to `true` to enable FIPS mode (default: `false`) |
   | `sshPublicKey` | SSH public key for node access |
   | `pullSecret.dockerconfigjson` | Base64-encoded Red Hat pull secret |
   | `nodes` | List of per-node network configurations (see below) |

   Each entry in `nodes` needs:

   | Value | Description |
   |-------|-------------|
   | `name` | Node hostname |
   | `interface` | NIC device name (e.g. `eth0`, `eno1`) |
   | `macAddress` | NIC MAC address |
   | `ip` | Static IP address |
   | `prefixLength` | Subnet prefix length (e.g. `23`) |
   | `gateway` | Default gateway |
   | `dns` | List of DNS server addresses |

2. Create an ArgoCD Application in `apps/<hub>/` that references the chart and values file.

3. Validate the rendered output:

   ```bash
   helm template <cluster-name> charts/spoke-cluster -f values/<hub>/spoke-cluster-<cluster-name>.yaml
   ```

## Deploy

Once the ArgoCD Application is synced, the resources are applied to the hub cluster automatically.

1. Wait for the discovery ISO to be generated:

   ```bash
   oc get infraenv <cluster-name> -n <cluster-namespace> -o jsonpath='{.status.isoDownloadURL}'
   ```

3. [Boot the bare metal nodes](docs/hardware-inventory-and-configuration.md#boot-configuration) from the discovery ISO.

4. As nodes boot the discovery ISO, they register as `Agent` resources on the hub cluster. Monitor their registration:

   ```bash
   oc get agents -n <cluster-namespace> -w
   ```

5. It is recommended that you set the agent's `spec.hostname` with the hostname of the matching node for easy identification:

   ```bash
   oc patch agent <agent-name> -n <cluster-namespace> --type merge -p '{"spec": {"hostname": "{{<hostname>|lower}}" } }'
   ```

6. Before approving agents, verify that each node has the correct role assigned (`master` or `worker`). The Assisted Installer auto-assigns roles based on `controlPlaneAgents` and `workerAgents` counts, but the assignment may not match your intent:

   ```bash
   oc get agents -n <cluster-namespace> -o custom-columns=NAME:.metadata.name,HOSTNAME:.spec.hostname,ROLE:.status.role
   ```

   If a node has the wrong role, reassign it:

   ```bash
   oc patch agent <agent-name> -n <cluster-namespace> --type merge -p '{"spec":{"role":"worker"}}'
   ```

7. Once roles are correct, approve each agent:

   ```bash
   oc patch agent <agent-name> -n <cluster-namespace> --type merge -p '{"spec":{"approved":true}}'
   ```

8. Once all agents are approved and validations pass, the installation begins automatically. Monitor progress:

   ```bash
   oc get agentclusterinstall <cluster-name> -n <cluster-namespace> -o jsonpath='{.status.conditions}' | python3 -m json.tool
   ```

9. After installation completes, retrieve the kubeconfig:

   ```bash
   oc get secret -n <cluster-namespace> <cluster-name>-admin-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > kubeconfig-<cluster-name>
   ```
