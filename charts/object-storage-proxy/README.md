# object-storage-proxy

An in-cluster reverse proxy that exposes object storage at a stable,
default-trusted endpoint: `https://storage.massopen.cloud`. It lets any
workload in the cluster reach object storage over TLS without custom CA
configuration.

The chart lives in `charts/object-storage-proxy`.

## How it works

The design chains three constraints together:

1. Public DNS needs a stable IP, so the Service is given a pinned
   ClusterIP.
2. A default-trusted certificate needs a public DNS name, so a Let's
   Encrypt certificate is issued for `storage.massopen.cloud`.
3. The proxy needs to reach the backend on a separate network, so it
   attaches to a secondary Multus network.

A public A record maps `storage.massopen.cloud` to the pinned ClusterIP.
Because a ClusterIP is served locally by each cluster's kube-proxy, a
single DNS record resolves to the local proxy in every cluster that uses
the same service CIDR, and traffic never leaves the cluster. The record
points at an internal address, so the name only resolves usefully from
inside the cluster.

## Components

Proxy (`templates/daemonset.yaml`)
: An HAProxy DaemonSet, running one instance per node. It terminates TLS
  on 8443 and serves plain HTTP on 8080,
  forwarding to the backend. `/healthz` backs the liveness and readiness
  probes. An init container concatenates the certificate and key into the
  single bundle HAProxy expects. Timeouts, thread count, connection limits
  and resource requests/limits are tuned for object storage transfers via
  the `proxy` values.

Service (`templates/service.yaml`)
: A ClusterIP Service with a pinned `clusterIP` (default `172.31.0.53`),
  publishing ports 443 (https) and 80 (http). The pinned IP is what the
  public DNS record targets.

Certificate (`templates/externalsecret.yaml`)
: The Let's Encrypt certificate is issued out of band (DNS-01) and stored
  in AWS Secrets Manager. An ExternalSecret pulls `tls.crt` and `tls.key`
  into a `kubernetes.io/tls` secret that the proxy mounts. Rendered only
  when `externalSecret.remoteKey` is set.

Backend routing (`templates/configmap.yaml`)
: The HAProxy config defines a secure and an insecure backend pointing at
  `backend.address`. When `backend.host` is set, it overrides the Host
  header and the TLS SNI sent upstream; otherwise the incoming Host header
  is forwarded unchanged. The secure backend verifies the upstream
  certificate when `backend.verify` is set, optionally against a custom CA
  supplied in `backend.cacert`; otherwise verification is disabled.

Secondary network (`templates/nad.yaml`)
: A NetworkAttachmentDefinition creates a bridge network (`br-storage`)
  with whereabouts IPAM. The proxy pods attach to it so they can reach the
  backend object storage server, which lives on a separate L2 network.

## Key values

| Value | Purpose |
| --- | --- |
| `service.clusterIP` | Pinned ClusterIP the public DNS record targets. Required. |
| `backend.address` | Address of the upstream object storage server. Required. |
| `backend.host` | Optional Host header and SNI override for upstream requests. |
| `backend.verify` | Whether HAProxy verifies the secure backend's TLS certificate. Defaults to false. |
| `backend.cacert` | Optional custom CA certificate (PEM) to validate the backend against. Used only when `backend.verify` is true. |
| `network.name` | Name of the secondary network the pods attach to. |
| `network.cidr`, `network.range.start`, `network.range.end` | Address range for whereabouts IPAM. Required. |
| `network.routes` | Optional routes added to the secondary interface. |
| `externalSecret.remoteKey` | Secrets Manager key holding the certificate. Enables the ExternalSecret. |
| `externalSecret.secretStore`, `externalSecret.secretStoreType` | Secret store the certificate is pulled from. |
| `proxy.image` | HAProxy image. |
| `proxy.access_log` | Enables HAProxy access logging to stdout. |
| `proxy.threads` | HAProxy worker threads. Set to match the CPU limit. |
| `proxy.maxconn` | Maximum concurrent connections, global and per backend server. |
| `proxy.backendCheck` | Adds a TCP health check to the backend server. |
| `proxy.timeouts` | Connect, client, server, http-request, http-keep-alive and queue timeouts. Client and server are inactivity timeouts; raise them for large transfers. |
| `proxy.resources` | Resource requests and limits for the HAProxy container. |

## Operational notes

- The pinned ClusterIP must fall within the service CIDR of every target
  cluster and must be free. A cluster with a different service CIDR will
  reject the Service. Confirm the CIDR before deploying to a new cluster.
- The public record points at a private (RFC1918) address, so it only
  resolves usefully inside the cluster. Host-network pods that bypass
  cluster DNS cannot use it, the same as any ClusterIP.
- Certificate issuance and renewal happen out of band; the chart only
  consumes the result from Secrets Manager.
