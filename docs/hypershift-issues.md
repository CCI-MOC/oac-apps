# HyperShift bugs encountered during oac-prod deployment

## NetworkPolicy blocks Route-published services

When using the Agent platform with Route as the service publishing strategy, the HyperShift operator creates a `same-namespace` NetworkPolicy in the hosted control plane namespace (`clusters-oac-prod`) that restricts ingress to pods within the same namespace. This blocks the OpenShift router pods (in `openshift-ingress`) from reaching HCP service backends, causing Layer 4 timeouts for ignition-server-proxy, oauth, and konnectivity. Only kube-apiserver is unaffected because it has a separate `kas` NetworkPolicy that allows ingress from any source on port 6443.

The result is that agents cannot download ignition configs, and other Route-published services are unreachable through the management cluster's ingress.

Route publishing is a supported strategy for the Agent platform. The operator creates the routes and the NetworkPolicy, but the two are incompatible. The documentation does not mention any NetworkPolicy prerequisite for this configuration.

**Workaround:** Add a supplementary NetworkPolicy allowing ingress from the `openshift-ingress` namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-openshift-ingress
  namespace: clusters-oac-prod
spec:
  podSelector: {}
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          policy-group.network.openshift.io/ingress: ""
  policyTypes:
  - Ingress
```

This workaround must be applied per HCP namespace. Every new HostedCluster deploys its control plane into a new namespace with the same restrictive `same-namespace` NetworkPolicy, so this problem will recur for each cluster. The correct fix is in the HyperShift operator itself — it should either include an ingress-allowing NetworkPolicy when Route publishing is configured, or not create a policy that is incompatible with its own routes.

## Default IngressController routeSelector excludes HCP routes

The HyperShift operator labels all HCP routes with `hypershift.openshift.io/hosted-control-plane`. If the management cluster's default IngressController has a `routeSelector` with `operator: DoesNotExist` for this label (as is the case when a dedicated HCP IngressController was previously configured), these routes are excluded from the default router. The routes appear admitted in their status, but the router does not serve them, and connections fall through to default TLS termination with the wildcard certificate.

**Fix:** Remove the `routeSelector` exclusion from the default IngressController if no dedicated HCP IngressController exists.

## In-cluster API access fails with TLS error when using Route-based API publishing

When the APIServer service is published via Route, a per-node haproxy proxy (`172.20.0.1:6443`) forwards in-cluster kubernetes API traffic to the management cluster's router at `api-oac-prod.apps.infra.oac.int.massopen.cloud:443`. The haproxy operates in TCP mode, forwarding raw bytes from the client to the router.

Pods using in-cluster service account configuration connect to the kubernetes service ClusterIP (`172.31.0.1`). Because the destination is an IP address, the Go TLS library does not set an SNI hostname in the TLS ClientHello. The haproxy forwards this ClientHello as-is to the management cluster's router. The router requires SNI to match passthrough routes; without it, the router falls back to its default wildcard certificate (`*.apps.infra.oac.int.massopen.cloud`), which contains no IP SANs.

The result is that every pod using standard in-cluster API access fails with:

```
tls: failed to verify certificate: x509: cannot validate certificate for 172.31.0.1 because it doesn't contain any IP SANs
```

External API access (via the hostname) works because the correct SNI is sent. Pods using hostNetwork (konnectivity-agent, node-resolver) are unaffected because they do not route through the kubernetes service.

The cascade of failures:

1. `service-ca-operator` crashes with the TLS error and cannot create serving cert secrets.
2. `dns-default-metrics-tls` secret is never created, so CoreDNS pods are stuck in ContainerCreating.
3. ACM `application-manager` addon crashes with the same TLS error, so the `oac-prod-application-manager-cluster-secret` is never created.
4. The `GitOpsCluster` controller cannot register `oac-prod` with ArgoCD.
5. The `all-managed-clusters` ApplicationSet cannot generate applications for `oac-prod`.

The kube-apiserver's serving certificate does include `172.31.0.1` as an IP SAN — the cert is correct. The problem is that the router never passes through to it.

The haproxy config on the nodes (`/proc/<pid>/root/usr/local/etc/haproxy/haproxy.cfg`) shows a plain TCP proxy with no SNI injection:

```
backend remote_apiserver
  mode tcp
  server controlplane api-oac-prod.apps.infra.oac.int.massopen.cloud:443
```

This appears to be a gap in the HyperShift kube-apiserver proxy configuration for Route-based publishing: the node-level haproxy does not inject the backend hostname as SNI on the outgoing connection, so the router cannot perform TLS passthrough.

## Stale ignition CA due to race condition in assisted-service

When a HostedCluster is destroyed and immediately recreated, assisted-service can serve a stale ignition CA certificate from the previous cluster incarnation to agents.

The HyperShift operator generates a per-cluster self-signed CA (`ignition-root-ca`) and stores it in the `ignition-server-ca-cert` secret in the HCP namespace. assisted-service reads this secret during ClusterDeployment reconciliation and propagates the CA to agents via `GetIgnitionEndpointAndCert()` so they can verify the ignition endpoint's TLS certificate.

The race condition:

1. The old `oac-prod` HostedCluster was destroyed and a new one created.
2. assisted-service began reconciling the new ClusterDeployment at 17:38:16.
3. The new `ignition-server-ca-cert` secret was not created until 17:38:19 — 3 seconds later.
4. All reconciliation attempts failed with "secrets not found."
5. assisted-service fell back to the stale CA from the previous cluster (serial `448B18C82483AB77`, cached from 16:55) instead of the new CA (serial `6AB7B2EBBF242408`).
6. Agents received the stale CA cert, could not verify the ignition endpoint (whose serving cert was signed by the new CA), and failed the `api-vip-connectivity-check` with "certificate signed by unknown authority."

The core issue is that assisted-service does not invalidate its cached ignition CA when a ClusterDeployment is deleted and recreated, and it does not retry the secret lookup on subsequent reconciliation cycles after the initial failure.

**Workaround:** Trigger a ClusterDeployment reconciliation (e.g., by annotating it) after confirming the `ignition-server-ca-cert` secret exists in the HCP namespace.

## Agents stuck reclaiming after HostedCluster destroy-and-recreate

When a HostedCluster is destroyed and recreated, agents from the previous cluster can become permanently stuck in `reclaiming` state. The `ai-deprovision` finalizer on each Agent prevents it from transitioning back to an assignable state, and the new cluster's CAPI Machines report `NoSuitableAgents` indefinitely.

During normal deprovisioning, assisted-service puts agents into `reclaiming` state and expects spoke-side cleanup (node drain and cordon) to complete before unbinding. When the old spoke cluster no longer exists, this cleanup can never complete, and the agents remain stuck.

The state of a stuck agent:

- `spec.clusterDeploymentName` is cleared (the binding has been removed from the spec)
- `status.conditions[type=Bound]` still reports `True` with message "The agent is bound to a cluster deployment"
- `status.debugInfo.state` is `reclaiming` with `stateInfo: "Host is waiting to be unbound from the cluster"`
- `status.deprovision_info` still references the old cluster name and namespace
- The `ai-deprovision` finalizer is present
- The label `agent-install.openshift.io/clusterdeployment-namespace` still points to the old HCP namespace

The chain of events:

1. The old `oac-prod` HostedCluster was deleted.
2. assisted-service put all three agents into `reclaiming` state with the `ai-deprovision` finalizer.
3. The agents waited for spoke-side unbind (drain/cordon from the old hosted cluster).
4. The old spoke cluster was fully destroyed before the unbind completed.
5. A new `oac-prod` HostedCluster was created. The new HCP namespace `clusters-oac-prod` was recreated and new CAPI Machines were provisioned.
6. The CAPI Machines reported `NoSuitableAgents` because all agents were still stuck in `reclaiming` from the previous incarnation.
7. assisted-service's internal database still associated the agents with the old cluster's internal ID, and the `Bound: True` condition persisted despite the spec being cleared.

The core issue is that assisted-service has no timeout or fallback for the spoke-side unbind. When the spoke cluster is destroyed before the unbind completes, the agents are stranded indefinitely.

**Workaround attempts that failed:**

- Removing the `ai-deprovision` finalizer from the Agent CR has no lasting effect — the assisted-service controller re-adds it on the next reconciliation cycle because the host is still in `reclaiming` state in its internal database.
- Removing the stale `agent-install.openshift.io/clusterdeployment-namespace` label is similarly ineffective.
- The assisted-service REST API's `UnbindHost` endpoint (`POST /v2/infra-envs/{id}/hosts/{id}/actions/unbind`) uses the `userAuth` security scheme, which is explicitly disabled when `AUTH_TYPE=local` (the default for MCE-managed installations), making it inaccessible.

The agents must complete their spoke-side cleanup (node drain/cordon) before the assisted-service will transition them out of `reclaiming`. When the spoke cluster no longer exists, this is a deadlock.

**Recovery:** The only effective recovery was to reset the assisted-service database entirely:

1. Scale down the assisted-service deployment.
2. Remove the `ai-deprovision` finalizer from all stuck Agent CRs (while the controller is down so it cannot re-add them).
3. Delete all Agent CRs.
4. Delete the `postgres` PVC in the `multicluster-engine` namespace.
5. Allow the MCE operator to recreate the assisted-service deployment and PVC with a fresh database.
6. Reboot the hosts into the discovery ISO so they re-register as new agents.

The InfraEnv CR does not need to be recreated — the controller reconciles the existing CR against the fresh database. This recovery destroys all assisted-service state, so it is only viable when no other clusters or hosts depend on the same assisted-service instance.

## HostedCluster deletion stuck on AgentMachine pre-terminate hook

When deleting a HostedCluster on the Agent platform, CAPI Machines can become stuck in `Deleting` state indefinitely. The `PreTerminateDeleteHookSucceeded` condition reports `WaitingExternalHook`, blocking the entire deletion chain: Machines → NodePool → CAPI Cluster → HostedCluster finalizer.

Each Machine has a `pre-terminate.delete.hook.machine.cluster.x-k8s.io/agentmachine` annotation that the Agent CAPI provider is supposed to remove after detaching the agent from the hosted cluster. The provider fails to remove this annotation even after the agents have been successfully detached and returned to `auto-assign` status in the agent namespace.

The deletion chain:

1. HostedCluster deletion is initiated, setting a `deletionTimestamp`.
2. The HyperShift operator waits for the CAPI Cluster (`oac-prod-vbj9z`) to be deleted.
3. The CAPI Cluster waits for all Machines to be deleted.
4. Each Machine waits for the `pre-terminate.delete.hook.machine.cluster.x-k8s.io/agentmachine` annotation to be removed.
5. The `capi-provider` is responsible for removing the annotation but does not do so.
6. The operator logs `"failed to delete nodepool: there are still Machines in for NodePool"` in a loop.

Meanwhile, the agents referenced by the Machines are already detached and show `auto-assign` status in the `hardware-inventory` namespace, indicating the provider completed the detach but failed to clear the hook annotation.

**Workaround:** Manually remove the pre-terminate hook annotation from each stuck Machine:

```bash
for machine in $(oc get machines.cluster.x-k8s.io -n clusters-<cluster> \
    --no-headers -o custom-columns=NAME:.metadata.name); do
  oc annotate machines.cluster.x-k8s.io "$machine" \
    -n clusters-<cluster> \
    pre-terminate.delete.hook.machine.cluster.x-k8s.io/agentmachine-
done
```

This allows the Machines to finish deleting, which unblocks the rest of the deletion chain.
