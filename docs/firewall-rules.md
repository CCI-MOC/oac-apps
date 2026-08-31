# Firewall & HAProxy setup for a new hosted cluster

This describes the pfSense (`fw1`/`fw2`) configuration required to expose a
new hosted cluster on the `oac-prod-infra` hub. Apply every change on
**both HA members**. pfSense is configured through its web UI, so this is a
checklist, not a set of commands. A runnable verification helper lives
alongside this file at `docs/firewall-rules.sh`
(`./docs/firewall-rules.sh verify`).

## What the firewall exposes

A hosted cluster has three externally reachable services:

| Service                  | Ports   | Backend it must reach                           |
| ------------------------ | ------- | ----------------------------------------------- |
| API (kube-apiserver)     | 6443    | the cluster's pinned APIServer LoadBalancer IP  |
| Ingress (guest `*.apps`) | 80, 443 | the guest cluster's `router-default` MetalLB IP |
| OAuth (browser login)    | 443     | the hub's shared hosted-clusters router         |

Ingress and OAuth both need port 443, so they **cannot share a VIP**. Each
cluster therefore uses **two WAN CARP VIPs**: one for ingress + API, and a
separate one for OAuth.

## Why the data-plane needs explicit rules

The HCP control plane dials these VIPs from _inside_ the guest network over
konnectivity — the ingress canary hits the ingress VIP on 443, and the
console hits the OAuth VIP on 443. A CARP VIP counts as the firewall itself
(`(self)`), and a global rule blocks `(self)` traffic on the management
ports (443/80/22, the `PORTS_FW_ACCESS` alias). So reaching a VIP on 80 or
443 from the guest data-plane requires a pass rule placed **above** that
block. Port 6443 is not a management port, so it is never blocked and needs
no data-plane rule.

If the data-plane rule is missing, the ingress and console operators go
`Degraded` even though external users are unaffected.

## Inputs for a new cluster

Collect these before you start (values shown are the `oac-prod-workload0`
example):

| Input           | Example              | Notes                                      |
| --------------- | -------------------- | ------------------------------------------ |
| Cluster name    | `oac-prod-workload0` |                                            |
| Ingress VIP     | `129.10.5.104`       | serves ingress 80/443 **and** API 6443     |
| OAuth VIP       | `129.10.5.103`       | serves OAuth 443 only                      |
| Guest router LB | `10.20.13.10`        | guest `router-default` MetalLB IP (80/443) |
| API-internal LB | `10.20.9.13`         | this cluster's pinned APIServer IP (6443)  |
| HCP router LB   | `10.20.9.10`         | hub-shared hosted-clusters router (443)    |

The **HCP router LB is the same for every cluster on the hub** — its
HAProxy backend (`oac-prod-infra-hcp-router`) already exists; reuse it.

## DNS (created by external-dns / the hosted-cluster chart — listed for reference)

- `api-external-<cluster>.hcp.oac.massopen.cloud` → ingress VIP (explicit
  record)
- `*.apps.<cluster>.hcp.oac.massopen.cloud` → ingress VIP (explicit record)
- `oauth-<cluster>.hcp.oac.massopen.cloud` → OAuth VIP (via the hub-wide
  `*.hcp` wildcard)
- `api-internal-<cluster>.hcp-int.oac.massopen.cloud` → API-internal LB
  (internal only)

The `*.hcp` wildcard (OAuth) and the guest `*.apps` wildcard (ingress)
**must resolve to different VIPs**, or 443 collides.

## 1. Virtual IPs — _Firewall › Virtual IPs_

Create the ingress VIP and the OAuth VIP as **CARP** VIPs on the **WAN**
interface, each with a unique VHID. (`oac-prod-workload0` uses VHID 28 for
`.104` and VHID 27 for `.103`.)

## 2. HAProxy — _Services › HAProxy_

All frontends are type **tcp** with **SSL offloading OFF** (TLS is passed
through to the backend). Backends are plain TCP.

**Backends:**

| Backend                              | Server                 |
| ------------------------------------ | ---------------------- |
| `<cluster>-ingress-insecure`         | guest router LB : 80   |
| `<cluster>-ingress-secure`           | guest router LB : 443  |
| `<cluster>-api`                      | API-internal LB : 6443 |
| `oac-prod-infra-hcp-router` (shared) | HCP router LB : 443    |

**Frontends:**

| Frontend                     | Bind               | Default backend              |
| ---------------------------- | ------------------ | ---------------------------- |
| `<cluster>-ingress-insecure` | ingress VIP : 80   | `<cluster>-ingress-insecure` |
| `<cluster>-ingress-secure`   | ingress VIP : 443  | `<cluster>-ingress-secure`   |
| `<cluster>-api`              | ingress VIP : 6443 | `<cluster>-api`              |
| `<cluster>-oauth`            | OAuth VIP : 443    | `oac-prod-infra-hcp-router`  |

> **Check the shared backend's server IP is exactly the HCP router LB.** A
> wrong IP here produces `TLS connect error: unexpected eof while reading`:
> HAProxy accepts the TCP connection but cannot reach the backend, so the
> TLS handshake dies. (This session hit it as a `10.29.9.10` vs
> `10.20.9.10` typo.)

## 3. Firewall rules — _Firewall › Rules_

**External inbound — WAN transit interface (`opt4`, "NEU").** Lets the
world reach the VIPs:

| Action | Proto | Source | Destination | Port |
| ------ | ----- | ------ | ----------- | ---- |
| pass   | tcp   | any    | ingress VIP | 80   |
| pass   | tcp   | any    | ingress VIP | 443  |
| pass   | tcp   | any    | ingress VIP | 6443 |
| pass   | tcp   | any    | OAuth VIP   | 443  |

**Data-plane — guest node interface (`opt19`, "VL216").** Lets
konnectivity-tunneled control-plane traffic reach the VIPs. **Place these
above the "Do not allow FW management access" block rule.** No gateway, no
NAT:

| Action | Proto | Source | Destination | Port |
| ------ | ----- | ------ | ----------- | ---- |
| pass   | tcp   | any    | ingress VIP | 80   |
| pass   | tcp   | any    | ingress VIP | 443  |
| pass   | tcp   | any    | OAuth VIP   | 443  |

Port 6443 needs no data-plane rule (not a management port, so not blocked;
the existing "Allow outside for NAT" rule already permits it).

## 4. Verify

From a shell whose `KUBECONFIG` points at the guest cluster, run
`./docs/firewall-rules.sh verify`. It TCP-probes each VIP:port from a
data-plane node, tests the OAuth TLS handshake, and prints the `ingress`
and `console` operator status. Both operators should report
`AVAILABLE=True` and `DEGRADED=False`.
