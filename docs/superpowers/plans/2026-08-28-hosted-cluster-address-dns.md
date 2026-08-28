# Hosted-cluster address & DNS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Minimize per-cluster addressing/DNS config for hosted clusters by deriving all service hostnames under facing-specific hub domains, making APIServer the only LoadBalancer, routing OAuth/Konnectivity/Ignition through the dedicated router under hub-wide wildcards, and auto-generating only the two API DNS records.

**Architecture:** All changes are Helm-template edits in three charts. A shared helper layer (`charts/hosted-cluster/templates/_helpers.tpl`) resolves each service's hostname from a per-service *facing* (`internal`/`external`/`base`) to a domain (`hcpInternalDomain` / `hcpExternalDomain` / `baseDomain`). Templates consume the helpers; behavior is proven with `helm-unittest` suites that render one template each.

**Tech Stack:** Helm 3/4 templating, `helm-unittest` v1.1.2 (`helm unittest`), `ct lint` (chart-testing), MetalLB CRDs, cert-manager, HyperShift HostedCluster, redhat-cop Patch operator, external-dns shadow Services.

**Spec:** `docs/superpowers/specs/2026-08-28-hosted-cluster-address-dns-design.md`

## Global Constraints

- **Verify templates after every template change** (project rule): run the affected `helm unittest` suite and, where noted, `helm template`. Never leave the chart un-renderable between commits.
- **Only `APIServer` may be a `LoadBalancer`** on the Agent platform; only `APIServer` may carry `ipAddress` / `externalIpAddress`. Any other service with `ipAddress` must fail the template.
- **`hcpInternalDomain` is required** (fail-closed, no chart default), enforced via a helper mirroring `hosted-cluster.baseDomain`. **`hcpExternalDomain` is optional** and defaults to `hcpInternalDomain`.
- **Naming convention (verbatim):**
  - `api-internal-<cluster>.<hcpInternalDomain>` — pinned API LB IP; `loadBalancer.hostname`; KAS SAN.
  - `api-external-<cluster>.<hcpExternalDomain>` — API external firewall IP; `kubeAPIServerDNSName`.
  - `oauth-<cluster>.<hcpExternalDomain>` — router external firewall IP.
  - `konnectivity-<cluster>.<hcpInternalDomain>`, `ignition-<cluster>.<hcpInternalDomain>` — router internal IP.
- **`helm-unittest` renders only the templates listed in a suite's `templates:`** field. A suite must set every hub value consumed by its listed templates, and *only* those. Do not add `hcpInternalDomain` to suites whose template does not consume it (e.g. `ipaddresspool_test`, `service_patches_test`, `clusterlabels_test`).
- **GPG signing note:** the environment's commit-signing key is expired. If `git commit` fails with a GPG error, retry the same commit with `git -c commit.gpgsign=false commit ...`.
- **Test runner:** `helm unittest -f 'tests/unit/*_test.yaml' charts/<chart>` runs a chart's suites; `-f 'tests/unit/<name>_test.yaml'` runs one suite.

## File Structure

- `charts/hosted-cluster/templates/_helpers.tpl` — MODIFY: add `hcpInternalDomain`, `hcpExternalDomain`, `facingDomain`, `kubeAPIServerDNSName` helpers; add `facing` to `serviceDefaults`; change `serviceHostname` to resolve the domain from `facing`; update `oauthHostname`.
- `charts/hosted-cluster/templates/hostedcluster.yaml` — MODIFY: new `serviceHostname` call signature; APIServer → LoadBalancer + `api-internal` name; `kubeAPIServerDNSName` from helper.
- `charts/hosted-cluster/templates/certificate-api.yaml` — MODIFY: `kubeAPIServerDNSName` from helper.
- `charts/hosted-cluster/templates/certificate-oauth.yaml` — no edit (uses `oauthHostname` helper), but its test changes.
- `charts/hosted-cluster/templates/dns-records.yaml` — MODIFY: new `serviceHostname` signature (Task 1); APIServer-only autoGenerate emitting exactly two records (Task 2).
- `charts/hosted-cluster/templates/ipaddresspool.yaml`, `service-patches.yaml` — MODIFY: restrict to APIServer; fail on any non-APIServer `ipAddress`.
- `charts/hosted-cluster/values.yaml` — MODIFY: add `hcpInternalDomain`/`hcpExternalDomain`; document APIServer `ipAddress`/`externalIpAddress`.
- `charts/hosted-cluster/ci/test-values.yaml` — MODIFY: make self-renderable (`baseDomain`, `managementCluster`, `hcpInternalDomain`) and adopt the new interface.
- `charts/hosted-cluster/tests/unit/*` — MODIFY: `hostedcluster_test`, `dns_records_test`, `certificate_test`, `certificate_oauth_test`, `ipaddresspool_test`, `service_patches_test`, `hub_values_required_test`.
- `charts/cluster-certificates/templates/ingresscontroller.yaml` — MODIFY: default-router `namespaceSelector` exclusion.
- `charts/cluster-certificates/tests/unit/ingresscontroller_test.yaml` — CREATE.
- `hosted-clusters/oac-dev-infra/values.yaml` — MODIFY: add `hcpInternalDomain`.
- `hosted-clusters/oac-dev-infra/oac-dev-workload1/values.yaml` — MODIFY: adopt minimal interface.
- `hosted-clusters/oac-dev-infra/oac-prod/values.yaml` — MODIFY (Task 6, gated): migrate to new interface.

---

## Task 1: Routed services (OAuth/Konnectivity/Ignition) move to hub facing-domains

Introduces the domain helpers and the `facing` model, and switches the three
routed services + the OAuth certificate to the hub domains. APIServer and OIDC
stay on `baseDomain` (facing `base`) with unchanged behavior — the seam that
keeps this task independently green from Task 2.

**Files:**
- Modify: `charts/hosted-cluster/templates/_helpers.tpl`
- Modify: `charts/hosted-cluster/templates/hostedcluster.yaml:58`
- Modify: `charts/hosted-cluster/templates/dns-records.yaml:11`
- Modify: `charts/hosted-cluster/values.yaml`
- Modify: `charts/hosted-cluster/ci/test-values.yaml`
- Test: `charts/hosted-cluster/tests/unit/hostedcluster_test.yaml`
- Test: `charts/hosted-cluster/tests/unit/certificate_oauth_test.yaml`
- Test: `charts/hosted-cluster/tests/unit/dns_records_test.yaml`
- Test: `charts/hosted-cluster/tests/unit/hub_values_required_test.yaml`

**Interfaces:**
- Produces:
  - `hosted-cluster.hcpInternalDomain` (root ctx) → required string.
  - `hosted-cluster.hcpExternalDomain` (root ctx) → string, defaults to internal.
  - `hosted-cluster.facingDomain` (dict `facing`, `ctx`) → domain string.
  - `serviceDefaults` entries now carry `facing: internal|external|base`.
  - `hosted-cluster.serviceHostname` (dict `serviceConfig`, `prefix`, `facing`, `clusterName`, `ctx`) → hostname string. **Signature change:** `baseDomain` replaced by `facing`+`ctx`.
- Consumes: nothing from prior tasks.

- [ ] **Step 1: Update the OAuth/Konnectivity/Ignition assertions in `hostedcluster_test.yaml` to hub domains (failing test)**

Add `hcpInternalDomain` to the suite `set:` block (it is now consumed by the
OAuth path), and change the three routed-service hostname assertions. Replace
the suite header `set:` and the three affected tests so they read:

```yaml
set:
  clusterName: test-cluster
  baseDomain: apps.infra.oac.int.massopen.cloud
  hcpInternalDomain: hcp.infra.oac.int.massopen.cloud
```

```yaml
  - it: should default OAuthServer to Route with external-domain hostname
    asserts:
      - contains:
          path: spec.services
          content:
            service: OAuthServer
            servicePublishingStrategy:
              type: Route
              route:
                hostname: oauth-test-cluster.hcp.infra.oac.int.massopen.cloud
```

```yaml
  - it: should default Ignition and Konnectivity to Route with internal-domain hostnames
    asserts:
      - contains:
          path: spec.services
          content:
            service: Ignition
            servicePublishingStrategy:
              type: Route
              route:
                hostname: ignition-test-cluster.hcp.infra.oac.int.massopen.cloud
      - contains:
          path: spec.services
          content:
            service: Konnectivity
            servicePublishingStrategy:
              type: Route
              route:
                hostname: konnectivity-test-cluster.hcp.infra.oac.int.massopen.cloud
```

Also update the named-certificate OAuth assertion:

```yaml
  - it: should serve a named certificate for the OAuth hostname
    asserts:
      - equal:
          path: spec.configuration.apiServer.servingCerts.namedCertificates[1].names[0]
          value: oauth-test-cluster.hcp.infra.oac.int.massopen.cloud
      - equal:
          path: spec.configuration.apiServer.servingCerts.namedCertificates[1].servingCertificate.name
          value: test-cluster-oauth-certificate
```

- [ ] **Step 2: Run the suite to confirm it fails**

Run: `helm unittest -f 'tests/unit/hostedcluster_test.yaml' charts/hosted-cluster`
Expected: FAIL — OAuth/Ignition/Konnectivity still render `…apps.infra…`.

- [ ] **Step 3: Add the domain helpers and `facing` model to `_helpers.tpl`**

After the `hosted-cluster.managementCluster` helper, add:

```gotemplate
{{/*
Return the hub-level internal HCP domain, failing if unset.
*/}}
{{- define "hosted-cluster.hcpInternalDomain" -}}
{{- required "hcpInternalDomain must be set (supply it in the hub-level values file hosted-clusters/<hub>/values.yaml)" .Values.hcpInternalDomain -}}
{{- end -}}

{{/*
Return the hub-level external HCP domain, defaulting to the internal domain.
*/}}
{{- define "hosted-cluster.hcpExternalDomain" -}}
{{- .Values.hcpExternalDomain | default (include "hosted-cluster.hcpInternalDomain" .) -}}
{{- end -}}

{{/*
Resolve a service's domain from its facing.
Expects a dict with keys: facing, ctx (root context).
*/}}
{{- define "hosted-cluster.facingDomain" -}}
{{- if eq .facing "external" -}}
{{- include "hosted-cluster.hcpExternalDomain" .ctx -}}
{{- else if eq .facing "base" -}}
{{- include "hosted-cluster.baseDomain" .ctx -}}
{{- else -}}
{{- include "hosted-cluster.hcpInternalDomain" .ctx -}}
{{- end -}}
{{- end -}}
```

In `serviceDefaults`, add a `facing` line to each service (APIServer and OIDC
stay `base` for now):

```yaml
{{- define "hosted-cluster.serviceDefaults" -}}
APIServer:
  prefix: api
  defaultType: NodePort
  k8sServiceName: kube-apiserver
  facing: base
Ignition:
  prefix: ignition
  defaultType: Route
  k8sServiceName: ignition-server
  facing: internal
Konnectivity:
  prefix: konnectivity
  defaultType: Route
  k8sServiceName: konnectivity-server
  facing: internal
OAuthServer:
  prefix: oauth
  defaultType: Route
  k8sServiceName: oauth-openshift
  facing: external
OIDC:
  prefix: ""
  defaultType: Route
  k8sServiceName: ""
  facing: base
{{- end -}}
```

Replace `serviceHostname` to resolve the domain from facing:

```gotemplate
{{/*
Derive the hostname for a service.
Expects a dict with keys: serviceConfig, prefix, facing, clusterName, ctx.
Returns the hostname string, or empty string if none can be derived.
*/}}
{{- define "hosted-cluster.serviceHostname" -}}
{{- $hostname := dig "hostname" "" .serviceConfig -}}
{{- if not $hostname -}}
  {{- if .prefix -}}
    {{- $domain := include "hosted-cluster.facingDomain" (dict "facing" .facing "ctx" .ctx) -}}
    {{- $hostname = printf "%s-%s.%s" .prefix .clusterName $domain -}}
  {{- end -}}
{{- end -}}
{{- $hostname -}}
{{- end -}}
```

Update `oauthHostname` to pass `facing` + `ctx`:

```gotemplate
{{- define "hosted-cluster.oauthHostname" -}}
{{- $clusterName := required "clusterName is required" .Values.clusterName -}}
{{- $defaults := include "hosted-cluster.serviceDefaults" . | fromYaml -}}
{{- $svcDef := index $defaults "OAuthServer" -}}
{{- $serviceConfig := dig "OAuthServer" dict .Values.services -}}
{{- include "hosted-cluster.serviceHostname" (dict "serviceConfig" $serviceConfig "prefix" $svcDef.prefix "facing" $svcDef.facing "clusterName" $clusterName "ctx" .) -}}
{{- end -}}
```

- [ ] **Step 4: Update the two `serviceHostname` call sites to the new signature**

In `hostedcluster.yaml`, line ~58, change the call to pass `facing` and `ctx`:

```gotemplate
    {{- $hostname := include "hosted-cluster.serviceHostname" (dict "serviceConfig" $serviceConfig "prefix" $svcDef.prefix "facing" $svcDef.facing "clusterName" $clusterName "ctx" $) }}
```

In `dns-records.yaml`, line ~11, change the call the same way (behavior for
APIServer is unchanged because its facing is `base`):

```gotemplate
{{- $hostname := include "hosted-cluster.serviceHostname" (dict "serviceConfig" $serviceConfig "prefix" (dig "prefix" "" $svcDef) "facing" (dig "facing" "internal" $svcDef) "clusterName" $clusterName "ctx" $) }}
```

- [ ] **Step 5: Add the new hub values to `values.yaml`**

After the `managementCluster: ""` block, add:

```yaml
# hcpInternalDomain is a per-hub value with no safe default (fail-closed like
# baseDomain). hcpExternalDomain is optional and inherits hcpInternalDomain when
# empty; they differ only when the shared router serves both externally-NAT'd
# and internal-only names. See docs/superpowers/specs/2026-08-28-hosted-cluster-address-dns-design.md
hcpInternalDomain: ""
hcpExternalDomain: ""
```

- [ ] **Step 6: Run the hostedcluster + oauth-cert suites to confirm they pass**

Run: `helm unittest -f 'tests/unit/hostedcluster_test.yaml' -f 'tests/unit/certificate_oauth_test.yaml' charts/hosted-cluster`
Expected: `hostedcluster_test` PASS. `certificate_oauth_test` FAIL (asserts old domain) — fixed next.

- [ ] **Step 7: Fix `certificate_oauth_test.yaml`**

Add `hcpInternalDomain` to the suite `set:` and update the derived-name assertion:

```yaml
set:
  clusterName: test-cluster
  baseDomain: apps.infra.oac.int.massopen.cloud
  hcpInternalDomain: hcp.infra.oac.int.massopen.cloud
```

```yaml
  - it: should default dnsNames from clusterName and external domain
    asserts:
      - equal:
          path: spec.dnsNames[0]
          value: oauth-test-cluster.hcp.infra.oac.int.massopen.cloud
```

(Leave the "hostname override" and "secret name" tests unchanged.)

- [ ] **Step 8: Fix `dns_records_test.yaml` suite setup (routed-service render)**

Add `hcpInternalDomain` to the suite `set:` block so tests that set
`OAuthServer` can resolve the external domain during rendering:

```yaml
set:
  clusterName: test-cluster
  baseDomain: apps.infra.oac.int.massopen.cloud
  hcpInternalDomain: hcp.infra.oac.int.massopen.cloud
  dns:
    enabled: true
    autoGenerate: true
```

(No assertion changes in this task — APIServer records still use `base`/`api`.)

- [ ] **Step 9: Add the `hcpInternalDomain` fail-closed test to `hub_values_required_test.yaml`**

Append:

```yaml
  - it: should fail closed when hcpInternalDomain is not supplied by the hub
    set:
      baseDomain: apps.infra.oac.int.massopen.cloud
      managementCluster: oac-infra-dev
      services:
        OAuthServer: {}
    templates:
      - templates/hostedcluster.yaml
    asserts:
      - failedTemplate:
          errorMessage: "hcpInternalDomain must be set (supply it in the hub-level values file hosted-clusters/<hub>/values.yaml)"
```

- [ ] **Step 10: Make `ci/test-values.yaml` self-renderable**

Add the three hub values at the top so `helm template`/`ct lint` can render the
chart standalone:

```yaml
baseDomain: apps.infra.oac.int.massopen.cloud
managementCluster: oac-infra-dev
hcpInternalDomain: hcp.infra.oac.int.massopen.cloud
```

- [ ] **Step 11: Run the full hosted-cluster suite and a standalone render**

Run: `helm unittest -f 'tests/unit/*_test.yaml' charts/hosted-cluster`
Expected: all suites PASS.
Run: `helm template charts/hosted-cluster -f charts/hosted-cluster/ci/test-values.yaml >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 12: Commit**

```bash
git add charts/hosted-cluster/templates/_helpers.tpl \
        charts/hosted-cluster/templates/hostedcluster.yaml \
        charts/hosted-cluster/templates/dns-records.yaml \
        charts/hosted-cluster/values.yaml \
        charts/hosted-cluster/ci/test-values.yaml \
        charts/hosted-cluster/tests/unit/hostedcluster_test.yaml \
        charts/hosted-cluster/tests/unit/certificate_oauth_test.yaml \
        charts/hosted-cluster/tests/unit/dns_records_test.yaml \
        charts/hosted-cluster/tests/unit/hub_values_required_test.yaml
git commit -m "Route OAuth/Konnectivity/Ignition hostnames under hub HCP domains"
```

---

## Task 2: APIServer → LoadBalancer with api-internal / api-external names

Flips APIServer to a LoadBalancer with the `api-internal` publishing name and
the `api-external` `kubeAPIServerDNSName`, centralizes the DNS-name default in a
helper, and rewrites autoGenerate to emit exactly the two API records.

**Files:**
- Modify: `charts/hosted-cluster/templates/_helpers.tpl`
- Modify: `charts/hosted-cluster/templates/hostedcluster.yaml`
- Modify: `charts/hosted-cluster/templates/certificate-api.yaml`
- Modify: `charts/hosted-cluster/templates/dns-records.yaml`
- Test: `charts/hosted-cluster/tests/unit/hostedcluster_test.yaml`
- Test: `charts/hosted-cluster/tests/unit/certificate_test.yaml`
- Test: `charts/hosted-cluster/tests/unit/dns_records_test.yaml`

**Interfaces:**
- Consumes: helpers and `facing` model from Task 1.
- Produces: `hosted-cluster.kubeAPIServerDNSName` (root ctx) → string, defaults to `api-external-<cluster>.<hcpExternalDomain>`, overridable via `.Values.kubeAPIServerDNSName`. `serviceDefaults.APIServer` now `{prefix: api-internal, defaultType: LoadBalancer, facing: internal, k8sServiceName: kube-apiserver}`. autoGenerate emits documents `dns-apiserver-internal-<cluster>` and `dns-apiserver-external-<cluster>`.

- [ ] **Step 1: Rewrite the APIServer assertions in `hostedcluster_test.yaml` (failing tests)**

Replace the APIServer default test, the custom-hostname NodePort test, the
preserve-fields test, the `kubeAPIServerDNSName` default test, and the
named-cert[0] test:

```yaml
  - it: should default APIServer to LoadBalancer with internal-domain hostname
    asserts:
      - contains:
          path: spec.services
          content:
            service: APIServer
            servicePublishingStrategy:
              type: LoadBalancer
              loadBalancer:
                hostname: api-internal-test-cluster.hcp.infra.oac.int.massopen.cloud
```

```yaml
  - it: should preserve additional strategy fields from values
    set:
      services:
        APIServer:
          servicePublishingStrategy:
            type: NodePort
            nodePort:
              port: 12345
    asserts:
      - contains:
          path: spec.services
          content:
            service: APIServer
            servicePublishingStrategy:
              type: NodePort
              nodePort:
                address: api-internal-test-cluster.hcp.infra.oac.int.massopen.cloud
                port: 12345
```

```yaml
  - it: should default kubeAPIServerDNSName to the external-domain name
    asserts:
      - equal:
          path: spec.kubeAPIServerDNSName
          value: api-external-test-cluster.hcp.infra.oac.int.massopen.cloud

  - it: should use the external-domain name in the API named certificate
    asserts:
      - equal:
          path: spec.configuration.apiServer.servingCerts.namedCertificates[0].names[0]
          value: api-external-test-cluster.hcp.infra.oac.int.massopen.cloud
```

Delete the now-obsolete test `should use custom hostname in NodePort strategy`
(APIServer no longer defaults to NodePort; the custom-hostname LoadBalancer test
already covers the override path). Leave `should allow overriding
kubeAPIServerDNSName` and `should use overridden kubeAPIServerDNSName in named
certificate` unchanged (override still wins).

- [ ] **Step 2: Run the suite to confirm it fails**

Run: `helm unittest -f 'tests/unit/hostedcluster_test.yaml' charts/hosted-cluster`
Expected: FAIL — APIServer still NodePort/`api-…`/`api.…`.

- [ ] **Step 3: Flip `serviceDefaults.APIServer` and add the `kubeAPIServerDNSName` helper**

In `_helpers.tpl`, change the APIServer block:

```yaml
APIServer:
  prefix: api-internal
  defaultType: LoadBalancer
  k8sServiceName: kube-apiserver
  facing: internal
```

Add after `oauthHostname`:

```gotemplate
{{/*
Derive the external API DNS name (kubeAPIServerDNSName).
*/}}
{{- define "hosted-cluster.kubeAPIServerDNSName" -}}
{{- $clusterName := required "clusterName is required" .Values.clusterName -}}
{{- .Values.kubeAPIServerDNSName | default (printf "api-external-%s.%s" $clusterName (include "hosted-cluster.hcpExternalDomain" .)) -}}
{{- end -}}
```

- [ ] **Step 4: Use the helper in `hostedcluster.yaml`**

Change line ~3 from the inline default to:

```gotemplate
{{- $kubeAPIServerDNSName := include "hosted-cluster.kubeAPIServerDNSName" . }}
```

- [ ] **Step 5: Run the hostedcluster suite to confirm it passes**

Run: `helm unittest -f 'tests/unit/hostedcluster_test.yaml' charts/hosted-cluster`
Expected: PASS.

- [ ] **Step 6: Update `certificate_test.yaml` (failing test)**

Add `hcpInternalDomain` to the suite `set:` (certificate-api now resolves the
external domain), and update the default assertion:

```yaml
set:
  clusterName: test-cluster
  baseDomain: apps.infra.oac.int.massopen.cloud
  hcpInternalDomain: hcp.infra.oac.int.massopen.cloud
```

```yaml
  - it: should default dnsNames to the external-domain name
    asserts:
      - equal:
          path: spec.dnsNames[0]
          value: api-external-test-cluster.hcp.infra.oac.int.massopen.cloud
```

(Leave the override test unchanged.)

- [ ] **Step 7: Point `certificate-api.yaml` at the helper**

Replace line ~3:

```gotemplate
{{- $kubeAPIServerDNSName := include "hosted-cluster.kubeAPIServerDNSName" . }}
```

Run: `helm unittest -f 'tests/unit/certificate_test.yaml' charts/hosted-cluster`
Expected: PASS.

- [ ] **Step 8: Rewrite the autoGenerate section of `dns_records_test.yaml` (failing tests)**

Replace the whole `tests:` list with the API-only behavior (keep the suite
header from Task 1):

```yaml
tests:
  - it: should generate internal and external API records for LoadBalancer with ipAddress
    set:
      services:
        APIServer:
          ipAddress: "10.20.5.10"
    asserts:
      - hasDocuments:
          count: 2
      - containsDocument:
          kind: Service
          apiVersion: v1
          name: dns-apiserver-internal-test-cluster
          any: true
      - equal:
          path: metadata.annotations["external-dns.alpha.kubernetes.io/hostname"]
          value: "api-internal-test-cluster.hcp.infra.oac.int.massopen.cloud"
        documentSelector:
          path: metadata.name
          value: dns-apiserver-internal-test-cluster
      - equal:
          path: metadata.annotations["external-dns.alpha.kubernetes.io/target"]
          value: "10.20.5.10"
        documentSelector:
          path: metadata.name
          value: dns-apiserver-internal-test-cluster
      - containsDocument:
          kind: Service
          apiVersion: v1
          name: dns-apiserver-external-test-cluster
          any: true
      - equal:
          path: metadata.annotations["external-dns.alpha.kubernetes.io/hostname"]
          value: "api-external-test-cluster.hcp.infra.oac.int.massopen.cloud"
        documentSelector:
          path: metadata.name
          value: dns-apiserver-external-test-cluster
      - equal:
          path: metadata.annotations["external-dns.alpha.kubernetes.io/target"]
          value: "10.20.5.10"
        documentSelector:
          path: metadata.name
          value: dns-apiserver-external-test-cluster

  - it: should target externalIpAddress for the external record when set
    set:
      services:
        APIServer:
          ipAddress: "10.20.5.10"
          externalIpAddress: "129.10.5.101"
    asserts:
      - hasDocuments:
          count: 2
      - equal:
          path: metadata.annotations["external-dns.alpha.kubernetes.io/target"]
          value: "129.10.5.101"
        documentSelector:
          path: metadata.name
          value: dns-apiserver-external-test-cluster

  - it: should use overridden kubeAPIServerDNSName for the external record
    set:
      kubeAPIServerDNSName: api.custom.example.com
      services:
        APIServer:
          ipAddress: "10.20.5.10"
    asserts:
      - equal:
          path: metadata.annotations["external-dns.alpha.kubernetes.io/hostname"]
          value: "api.custom.example.com"
        documentSelector:
          path: metadata.name
          value: dns-apiserver-external-test-cluster

  - it: should use custom APIServer hostname for the internal record
    set:
      services:
        APIServer:
          hostname: custom-internal.example.com
          ipAddress: "10.20.5.10"
    asserts:
      - equal:
          path: metadata.annotations["external-dns.alpha.kubernetes.io/hostname"]
          value: "custom-internal.example.com"
        documentSelector:
          path: metadata.name
          value: dns-apiserver-internal-test-cluster

  - it: should generate no records for routed services even with ipAddress absent
    set:
      services:
        OAuthServer:
          servicePublishingStrategy:
            type: Route
    asserts:
      - hasDocuments:
          count: 0

  - it: should not generate auto records when autoGenerate is false
    set:
      dns:
        enabled: true
        autoGenerate: false
      services:
        APIServer:
          ipAddress: "10.20.5.10"
    asserts:
      - hasDocuments:
          count: 0

  - it: should render manual records alongside auto-generated ones
    set:
      services:
        APIServer:
          ipAddress: "10.20.5.10"
      dns:
        enabled: true
        autoGenerate: true
        records:
          - name: ingress
            hostname: "*.apps.test-cluster.apps.infra.oac.int.massopen.cloud"
            target: "10.20.5.100"
    asserts:
      - hasDocuments:
          count: 3
      - containsDocument:
          kind: Service
          apiVersion: v1
          name: dns-apiserver-internal-test-cluster
          any: true
      - containsDocument:
          kind: Service
          apiVersion: v1
          name: dns-apiserver-external-test-cluster
          any: true
      - containsDocument:
          kind: Service
          apiVersion: v1
          name: dns-ingress-test-cluster
          any: true

  - it: should not generate any records when dns.enabled is false
    set:
      dns:
        enabled: false
        autoGenerate: true
      services:
        APIServer:
          ipAddress: "10.20.5.10"
    asserts:
      - hasDocuments:
          count: 0
```

- [ ] **Step 9: Run the suite to confirm it fails**

Run: `helm unittest -f 'tests/unit/dns_records_test.yaml' charts/hosted-cluster`
Expected: FAIL — old generic loop still emits `dns-api-…`/per-service records.

- [ ] **Step 10: Rewrite the autoGenerate block of `dns-records.yaml`**

Replace the entire `{{- if .Values.dns.autoGenerate }} … {{- end }}` block
(the per-service `range`) with an APIServer-only block. Keep the outer
`{{- if .Values.dns.enabled }}` wrapper and the trailing `.Values.dns.records`
loop intact.

```gotemplate
{{- if .Values.dns.autoGenerate }}
{{- $allDefaults := include "hosted-cluster.serviceDefaults" . | fromYaml }}
{{- $svcDef := index $allDefaults "APIServer" }}
{{- $apiConfig := dig "APIServer" dict .Values.services }}
{{- $internalHost := include "hosted-cluster.serviceHostname" (dict "serviceConfig" $apiConfig "prefix" $svcDef.prefix "facing" $svcDef.facing "clusterName" $clusterName "ctx" $) }}
{{- if and $apiConfig.ipAddress $internalHost }}
---
apiVersion: v1
kind: Service
metadata:
  name: dns-apiserver-internal-{{ $clusterName }}
  namespace: {{ $.Values.namespace }}
  labels:
    massopen.cloud/external-dns: "true"
  annotations:
    external-dns.alpha.kubernetes.io/hostname: {{ $internalHost | quote }}
    external-dns.alpha.kubernetes.io/target: {{ $apiConfig.ipAddress | quote }}
spec:
  type: ExternalName
  externalName: placeholder.invalid
{{- end }}
{{- $apiTarget := or $apiConfig.externalIpAddress $apiConfig.ipAddress }}
{{- if $apiTarget }}
---
apiVersion: v1
kind: Service
metadata:
  name: dns-apiserver-external-{{ $clusterName }}
  namespace: {{ $.Values.namespace }}
  labels:
    massopen.cloud/external-dns: "true"
  annotations:
    external-dns.alpha.kubernetes.io/hostname: {{ $kubeAPIServerDNSName | quote }}
    external-dns.alpha.kubernetes.io/target: {{ $apiTarget | quote }}
spec:
  type: ExternalName
  externalName: placeholder.invalid
{{- end }}
{{- end }}
```

Also update the top of `dns-records.yaml` (line ~4) to use the helper:

```gotemplate
{{- $kubeAPIServerDNSName := include "hosted-cluster.kubeAPIServerDNSName" . }}
```

Then remove the now-unused `serviceHostname` call added in Task 1 Step 4 (it was
inside the deleted range) — the only `serviceHostname` call now lives inside the
new block above.

- [ ] **Step 11: Run the suite to confirm it passes**

Run: `helm unittest -f 'tests/unit/dns_records_test.yaml' charts/hosted-cluster`
Expected: PASS.

- [ ] **Step 12: Run the full hosted-cluster suite and a standalone render**

Run: `helm unittest -f 'tests/unit/*_test.yaml' charts/hosted-cluster`
Expected: all PASS.
Run: `helm template charts/hosted-cluster -f charts/hosted-cluster/ci/test-values.yaml >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 13: Commit**

```bash
git add charts/hosted-cluster/templates/_helpers.tpl \
        charts/hosted-cluster/templates/hostedcluster.yaml \
        charts/hosted-cluster/templates/certificate-api.yaml \
        charts/hosted-cluster/templates/dns-records.yaml \
        charts/hosted-cluster/tests/unit/hostedcluster_test.yaml \
        charts/hosted-cluster/tests/unit/certificate_test.yaml \
        charts/hosted-cluster/tests/unit/dns_records_test.yaml
git commit -m "Publish APIServer as LoadBalancer with api-internal/api-external names"
```

---

## Task 3: Restrict MetalLB pinning to APIServer

Only `APIServer` can be a LoadBalancer, so only it may carry `ipAddress`. Make
`ipaddresspool.yaml` and `service-patches.yaml` fail closed for any other
service and simplify their loops.

**Files:**
- Modify: `charts/hosted-cluster/templates/ipaddresspool.yaml`
- Modify: `charts/hosted-cluster/templates/service-patches.yaml`
- Test: `charts/hosted-cluster/tests/unit/ipaddresspool_test.yaml`
- Test: `charts/hosted-cluster/tests/unit/service_patches_test.yaml`

**Interfaces:**
- Consumes: `serviceDefaults` (`k8sServiceName: kube-apiserver`) from earlier tasks.
- Produces: MetalLB `IPAddressPool`/`L2Advertisement` named `<cluster>-apiserver`; a Patch `<cluster>-apiserver-metallb`; a hard failure for any non-APIServer service carrying `ipAddress`.

- [ ] **Step 1: Update `ipaddresspool_test.yaml` (failing tests)**

Replace the two multi-service tests (`should generate resources for multiple
services with ipAddress` and `should not generate resources for services
without ipAddress`) with fail-closed coverage; keep the APIServer-only tests:

```yaml
  - it: should fail when a non-APIServer service has ipAddress
    set:
      services:
        OAuthServer:
          ipAddress: "10.20.5.11"
    asserts:
      - failedTemplate:
          errorMessage: 'service "OAuthServer" has ipAddress but only APIServer supports LoadBalancer publishing on the Agent platform'

  - it: should generate only APIServer resources and ignore other services without ipAddress
    set:
      services:
        APIServer:
          ipAddress: "10.20.5.10"
        OAuthServer:
          servicePublishingStrategy:
            type: Route
    asserts:
      - hasDocuments:
          count: 2
      - containsDocument:
          kind: IPAddressPool
          apiVersion: metallb.io/v1beta1
          name: test-cluster-apiserver
          any: true
```

- [ ] **Step 2: Run the suite to confirm it fails**

Run: `helm unittest -f 'tests/unit/ipaddresspool_test.yaml' charts/hosted-cluster`
Expected: FAIL — OAuthServer with ipAddress currently renders a pool instead of failing.

- [ ] **Step 3: Rewrite `ipaddresspool.yaml`**

```gotemplate
{{- $clusterName := required "clusterName is required" .Values.clusterName }}
{{- range $serviceName, $serviceConfig := .Values.services }}
{{- if $serviceConfig.ipAddress }}
{{- if ne $serviceName "APIServer" }}
{{- fail (printf "service %q has ipAddress but only APIServer supports LoadBalancer publishing on the Agent platform" $serviceName) }}
{{- end }}
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: {{ $clusterName }}-{{ lower $serviceName }}
  namespace: metallb-system
spec:
  autoAssign: false
  addresses:
    - {{ $serviceConfig.ipAddress }}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: {{ $clusterName }}-{{ lower $serviceName }}
  namespace: metallb-system
spec:
  ipAddressPools:
    - {{ $clusterName }}-{{ lower $serviceName }}
{{- end }}
{{- end }}
```

Run: `helm unittest -f 'tests/unit/ipaddresspool_test.yaml' charts/hosted-cluster`
Expected: PASS.

- [ ] **Step 4: Update `service_patches_test.yaml` (failing tests)**

Replace the OIDC-mapping test, the OAuthServer-target test, and the two-service
test with fail-closed coverage; keep the APIServer tests:

```yaml
  - it: should fail when a non-APIServer service has ipAddress
    set:
      services:
        OAuthServer:
          ipAddress: "10.20.5.11"
    asserts:
      - failedTemplate:
          errorMessage: 'service "OAuthServer" has ipAddress but only APIServer supports LoadBalancer publishing on the Agent platform'
```

Delete `should target oauth-openshift for OAuthServer`, `should fail for service
with ipAddress but no k8s service mapping`, and `should generate one Patch CR
per service with ipAddress`.

- [ ] **Step 5: Run the suite to confirm it fails**

Run: `helm unittest -f 'tests/unit/service_patches_test.yaml' charts/hosted-cluster`
Expected: FAIL.

- [ ] **Step 6: Update `service-patches.yaml` to fail on non-APIServer ipAddress**

In the per-service `range` (line ~47), replace the k8sServiceName-missing guard
with the APIServer guard. The block becomes:

```gotemplate
{{- range $serviceName, $serviceConfig := .Values.services }}
{{- if $serviceConfig.ipAddress }}
{{- if ne $serviceName "APIServer" }}
{{- fail (printf "service %q has ipAddress but only APIServer supports LoadBalancer publishing on the Agent platform" $serviceName) }}
{{- end }}
{{- $svcDef := dig $serviceName dict $allDefaults }}
{{- $k8sServiceName := dig "k8sServiceName" "" $svcDef }}
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: Patch
metadata:
  name: {{ $clusterName }}-{{ lower $serviceName }}-metallb
  namespace: {{ $hcpNamespace }}
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  serviceAccountRef:
    name: {{ $clusterName }}-patch-operator
  patches:
    metallb-pool:
      targetObjectRef:
        apiVersion: v1
        kind: Service
        name: {{ $k8sServiceName }}
        namespace: {{ $hcpNamespace }}
      patchType: application/strategic-merge-patch+json
      patchTemplate: |
        metadata:
          annotations:
            metallb.universe.tf/address-pool: {{ $clusterName }}-{{ lower $serviceName }}
{{- end }}
{{- end }}
```

(The `$hasPatches` detection loop and the SA/Role/RoleBinding block above it are
unchanged.)

- [ ] **Step 7: Run the suite to confirm it passes**

Run: `helm unittest -f 'tests/unit/service_patches_test.yaml' charts/hosted-cluster`
Expected: PASS.

- [ ] **Step 8: Run the full hosted-cluster suite**

Run: `helm unittest -f 'tests/unit/*_test.yaml' charts/hosted-cluster`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add charts/hosted-cluster/templates/ipaddresspool.yaml \
        charts/hosted-cluster/templates/service-patches.yaml \
        charts/hosted-cluster/tests/unit/ipaddresspool_test.yaml \
        charts/hosted-cluster/tests/unit/service_patches_test.yaml
git commit -m "Restrict MetalLB pinning to APIServer, fail closed otherwise"
```

---

## Task 4: Exclude HCP routes from the default IngressController

Add a `namespaceSelector` to the repo-managed default router so it never admits
routes from HCP namespaces (which the dedicated `hosted-clusters` router owns).

**Files:**
- Modify: `charts/cluster-certificates/templates/ingresscontroller.yaml`
- Create: `charts/cluster-certificates/tests/unit/ingresscontroller_test.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: default IngressController with `spec.namespaceSelector` excluding `hypershift.openshift.io/hosted-control-plane`.

- [ ] **Step 1: Create the failing test**

Create `charts/cluster-certificates/tests/unit/ingresscontroller_test.yaml`:

```yaml
suite: default IngressController HCP-route exclusion
templates:
  - templates/ingresscontroller.yaml
set:
  clusterDomain: example.com
tests:
  - it: should keep the default certificate
    asserts:
      - equal:
          path: spec.defaultCertificate.name
          value: default-ingress-certificate

  - it: should exclude HCP namespaces from the default router
    asserts:
      - equal:
          path: spec.namespaceSelector.matchExpressions[0].key
          value: hypershift.openshift.io/hosted-control-plane
      - equal:
          path: spec.namespaceSelector.matchExpressions[0].operator
          value: DoesNotExist
```

- [ ] **Step 2: Run the suite to confirm it fails**

Run: `helm unittest -f 'tests/unit/ingresscontroller_test.yaml' charts/cluster-certificates`
Expected: FAIL — `spec.namespaceSelector` does not exist yet.

- [ ] **Step 3: Add the exclusion to the template**

Edit `charts/cluster-certificates/templates/ingresscontroller.yaml` so `spec`
reads:

```yaml
spec:
  defaultCertificate:
    name: {{ .Values.certificates.ingress.certificate_name }}
  namespaceSelector:
    matchExpressions:
      - key: hypershift.openshift.io/hosted-control-plane
        operator: DoesNotExist
```

- [ ] **Step 4: Run the suite to confirm it passes**

Run: `helm unittest -f 'tests/unit/ingresscontroller_test.yaml' charts/cluster-certificates`
Expected: PASS.
Run: `helm template charts/cluster-certificates --set clusterDomain=example.com >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add charts/cluster-certificates/templates/ingresscontroller.yaml \
        charts/cluster-certificates/tests/unit/ingresscontroller_test.yaml
git commit -m "Exclude HCP-namespace routes from the default IngressController"
```

---

## Task 5: Wire the oac-dev-infra hub and adopt the interface on workload1

Set the hub's internal HCP domain and simplify `oac-dev-workload1` to the
minimal interface (validating the new defaults end to end). `oac-dev-workload1`
is internal-only, so `hcpExternalDomain` is left unset (inherits internal).

**Files:**
- Modify: `hosted-clusters/oac-dev-infra/values.yaml`
- Modify: `hosted-clusters/oac-dev-infra/oac-dev-workload1/values.yaml`

**Interfaces:**
- Consumes: the full hosted-cluster chart from Tasks 1–3.
- Produces: a hub that supplies `hcpInternalDomain`; a workload1 cluster whose only addressing input is `clusterName` + `services.APIServer.ipAddress`.

- [ ] **Step 1: Add the internal HCP domain to the hub values**

Append to `hosted-clusters/oac-dev-infra/values.yaml`:

```yaml
# Internal HCP wildcard domain: *.hcp.infra.oac.int.massopen.cloud resolves to
# the hosted-clusters router's MetalLB IP (10.20.3.10). hcpExternalDomain is
# omitted here (inherits the internal domain) because this hub's hosted clusters
# are internal-only; set it when a cluster exposes OAuth through the firewall.
hcpInternalDomain: hcp.infra.oac.int.massopen.cloud
```

- [ ] **Step 2: Simplify the workload1 values to the minimal interface**

Rewrite `hosted-clusters/oac-dev-infra/oac-dev-workload1/values.yaml` to:

```yaml
clusterName: oac-dev-workload1

services:
  APIServer:
    ipAddress: 10.20.3.11

nodePools:
  - name: compute
    replicas: 2
    agentLabelSelector:
      massopen.cloud/cluster: oac-dev-workload1

clusterLabels:
  - portworx

dns:
  enabled: true
  autoGenerate: true
```

(`servicePublishingStrategy.type: LoadBalancer` and the explicit `OAuthServer`
Route are dropped — they are now the defaults.)

- [ ] **Step 3: Render the layered values to verify**

Run:
```bash
helm template charts/hosted-cluster \
  -f hosted-clusters/oac-dev-infra/values.yaml \
  -f hosted-clusters/oac-dev-infra/oac-dev-workload1/values.yaml \
  > /tmp/workload1.yaml && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Confirm the derived names in the render**

Run:
```bash
grep -E 'hostname:|kubeAPIServerDNSName:|external-dns.alpha.kubernetes.io/(hostname|target)' /tmp/workload1.yaml
```
Expected to include:
- `kubeAPIServerDNSName: api-external-oac-dev-workload1.hcp.infra.oac.int.massopen.cloud`
- `loadBalancer.hostname: api-internal-oac-dev-workload1.hcp.infra.oac.int.massopen.cloud`
- `route.hostname: oauth-oac-dev-workload1.hcp.infra.oac.int.massopen.cloud`
- `route.hostname: konnectivity-oac-dev-workload1.hcp.infra.oac.int.massopen.cloud`
- `route.hostname: ignition-oac-dev-workload1.hcp.infra.oac.int.massopen.cloud`
- an `external-dns` internal record targeting `10.20.3.11` and an external record for the `api-external` name.

- [ ] **Step 5: Commit**

```bash
git add hosted-clusters/oac-dev-infra/values.yaml \
        hosted-clusters/oac-dev-infra/oac-dev-workload1/values.yaml
git commit -m "Wire oac-dev-infra hub domain and adopt minimal interface on workload1"
```

---

## Task 6: Migrate oac-prod values (GATED — coordinate with a maintenance window)

> **DO NOT MERGE OR LET ARGOCD SYNC THIS UNTIL THE MAINTENANCE WINDOW.** Applying
> it republishes the live API (NodePort → LoadBalancer, regenerates KAS SANs,
> reconnects nodes), moves the OAuth hostname (OAuth cert reissue **and GitHub
> OAuth app callback URL update**), and needs the two hub wildcards + firewall
> NATs in place. Follow the "Migration" section of the spec, after Task 5 has
> proven the path on workload1. Land this as its own PR aligned with the window.

**Files:**
- Modify: `hosted-clusters/oac-dev-infra/oac-prod/values.yaml`

**Interfaces:**
- Consumes: the full chart (Tasks 1–3) and the hub wiring (Task 5).
- Produces: an `oac-prod` values file on the new interface with no redundant overrides.

- [ ] **Step 1: Confirm the real cutover inputs before editing**

Confirm with the operator and record: the pinned API LoadBalancer IP (internal),
the API external firewall IP, the OAuth external firewall IP, and whether the
hub needs a distinct `hcpExternalDomain` (add it to
`hosted-clusters/oac-dev-infra/values.yaml` if OAuth is exposed under a separate
external wildcard). Substitute the real values below in place of the sanitized
`10.20.3.12` / `192.168.1.10`.

- [ ] **Step 2: Rewrite `oac-prod/values.yaml` to the new interface**

```yaml
clusterName: oac-prod

services:
  APIServer:
    ipAddress: 10.20.3.12          # pinned internal LB IP (confirm real value)
    externalIpAddress: 192.168.1.10 # API external firewall IP (confirm real value)

oauth:
  github:
    enabled: true
    clientID: "1234567890abcdef0123"
    secretPath: cluster/oac-infra-dev/hostedcluster/oac-prod/github-oauth-client-secret
    teams:
      - CCI-MOC/open-accelerator

nodePools:
  - name: compute
    replicas: 3
    agentLabelSelector:
      openstack/resource-class: fc830
      massopen.cloud/cluster: oac-prod
  - name: gpu
    replicas: 2
    agentLabelSelector:
      openstack/resource-class: lenovo-sd665nv3-h100
      massopen.cloud/cluster: oac-dev-workload0

clusterLabels:
  - gpu
  - github-oauth
  - portworx

dns:
  enabled: true
  autoGenerate: true
  records:
    - name: ingress
      hostname: "*.apps.oac-prod.apps.infra.oac.int.massopen.cloud"
      target: 192.168.1.1
```

Changes: removed the `issuerURL` override (the template defaults it correctly to
`…/oac-prod`), removed the redundant `OAuthServer` Route hostname override,
removed the manual `api-internal` DNS record (now auto-generated), switched the
API to a pinned LoadBalancer with an external IP, and enabled `autoGenerate`.

- [ ] **Step 3: Render the layered values to verify (no live apply)**

Run:
```bash
helm template charts/hosted-cluster \
  -f hosted-clusters/oac-dev-infra/values.yaml \
  -f hosted-clusters/oac-dev-infra/oac-prod/values.yaml \
  > /tmp/oac-prod.yaml && echo OK
```
Expected: `OK`, with `issuerURL: "https://oac-clusters-oidc.s3.us-east-1.amazonaws.com/oac-prod"`, the API published as LoadBalancer, and two `external-dns` API records.

- [ ] **Step 4: Commit (separate PR; hold for the window)**

```bash
git add hosted-clusters/oac-dev-infra/oac-prod/values.yaml
git commit -m "Migrate oac-prod to LoadBalancer API and derived DNS (hold for maintenance window)"
```

---

## Self-Review

**Spec coverage:**
- Naming convention → Tasks 1 (routed + OAuth) & 2 (api-internal/api-external). ✓
- APIServer LoadBalancer + pinned IP → Task 2 + Task 3 (MetalLB) + Task 5/6 (`ipAddress`). ✓
- Routed services via dedicated router under wildcards → Task 1 (hostnames); dedicated-router enablement is existing `hcp-config` values (already enabled in dev per `values/oac-dev-infra/local-cluster/hcp-config.yaml`) and needs no chart change. ✓
- Default-router exclusion → Task 4. ✓
- Certificates follow derived names → Tasks 1 (oauth) & 2 (api). ✓
- DNS: two auto API records, zero for routed, `dns.records` unchanged → Task 2. ✓
- Hub values `hcpInternalDomain` (required) / `hcpExternalDomain` (inherits) → Tasks 1 & 5. ✓
- Per-cluster interface reduction, issuerURL/oauth-override fixes → Tasks 5 & 6. ✓
- Migration (workload1 first, oac-prod gated) → Tasks 5 & 6. ✓
- Verification items (KAS SANs, shard labels, passthrough routes, OAuth named cert) are runtime confirmations, not template changes — they are called out in the spec and must be checked during rollout (Task 5 render + live validation), not unit-testable here.

**Placeholder scan:** oac-prod IPs in Task 6 are explicitly sanitized with a Step-1 gate to substitute real values; every template/test step carries concrete code. No TBD/TODO. ✓

**Type consistency:** `serviceHostname` dict keys (`serviceConfig`, `prefix`, `facing`, `clusterName`, `ctx`) are consistent across `_helpers.tpl`, `hostedcluster.yaml`, and `dns-records.yaml`. `facing` values (`internal`/`external`/`base`) are consistent between `serviceDefaults` and `facingDomain`. Helper names (`hcpInternalDomain`, `hcpExternalDomain`, `facingDomain`, `kubeAPIServerDNSName`, `oauthHostname`) match every call site. Auto-generated document names (`dns-apiserver-internal-<cluster>`, `dns-apiserver-external-<cluster>`) match between `dns-records.yaml` and `dns_records_test.yaml`. ✓
