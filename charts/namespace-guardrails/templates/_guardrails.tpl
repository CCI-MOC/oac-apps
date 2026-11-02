{{- /*
Default-deny NetworkPolicies and object-count quotas for the namespaces a
chart owns: namespaces that are not tenant projects and not openshift-
or kube- ones, such as the operators and agents we add. Tenant projects are
covered by user-projects and restrict-tenant-networks.

Closes ocp4-moderate configure-network-policies-namespaces and
resource-requests-quota (800-53 SC-7, SC-7(5), SC-6, CM-6). The checks
pass on ANY policy or quota existing; write these from observed traffic,
not to satisfy the check.

A chart lists this one as a dependency, includes "namespace-guardrails.render"
with its root context, and takes .Values.guardrails: a map of namespace to
settings, empty by default. Per namespace, every key is optional:
  quota:    ResourceQuota spec.hard. Object counts and storage only: a
            cpu/memory quota rejects pods that set no requests, which
            vendor operator pods often do.
  ingress:  default-deny ingress plus
              sameNamespace: true          pods in the namespace
              monitoringPorts: [...]       from openshift-monitoring
              hostNetworkPorts: [...]      from host-network (API server webhooks)
  egress:   default-deny egress plus
              apiAndDns: true              API server and DNS
              sameNamespace: true          pods in the namespace
  extraPolicies: list of {name, spec}, rendered verbatim.
Omit ingress or egress to leave that direction alone (for example where
an operator already ships ingress policies).
*/}}
{{- define "namespace-guardrails.render" -}}
{{- range $ns, $c := .Values.guardrails }}
{{- with $c.quota }}
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: oac-objects
  namespace: {{ $ns }}
spec:
  hard:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- if hasKey $c "ingress" }}
{{- $i := $c.ingress | default dict }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: {{ $ns }}
  annotations:
    # After the allow rules (wave 0): a deny applied first can cut off the
    # traffic Argo itself needs, such as ACM's cluster-proxy on a managed
    # cluster, and leave the sync unable to finish.
    argocd.argoproj.io/sync-wave: "1"
spec:
  podSelector: {}
  policyTypes: [Ingress]
{{- if $i.sameNamespace }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: {{ $ns }}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}
{{- end }}
{{- with $i.monitoringPorts }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-platform-monitoring
  namespace: {{ $ns }}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: openshift-monitoring
      ports:
        {{- range . }}
        - {port: {{ . }}, protocol: TCP}
        {{- end }}
{{- end }}
{{- with $i.hostNetworkPorts }}
---
# OVN-Kubernetes labels host-network traffic (the API server calling a
# webhook) with this namespace selector.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-webhook-from-host-network
  namespace: {{ $ns }}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              policy-group.network.openshift.io/host-network: ""
      ports:
        {{- range . }}
        - {port: {{ . }}, protocol: TCP}
        {{- end }}
{{- end }}
{{- end }}
{{- if hasKey $c "egress" }}
{{- $e := $c.egress | default dict }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: {{ $ns }}
  annotations:
    # After the allow rules (wave 0): a deny applied first can cut off the
    # traffic Argo itself needs, such as ACM's cluster-proxy on a managed
    # cluster, and leave the sync unable to finish.
    argocd.argoproj.io/sync-wave: "1"
spec:
  podSelector: {}
  policyTypes: [Egress]
{{- if $e.apiAndDns }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-api-dns
  namespace: {{ $ns }}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    {{- include "namespace-guardrails.apiAndDns" $ | nindent 4 }}
{{- end }}
{{- if $e.sameNamespace }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-same-namespace
  namespace: {{ $ns }}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - podSelector: {}
{{- end }}
{{- end }}
{{- range $c.extraPolicies }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ .name }}
  namespace: {{ $ns }}
spec:
  {{- toYaml .spec | nindent 2 }}
{{- end }}
{{- end }}
{{- end -}}

{{- /*
Egress rules for the API server and cluster DNS. OVN-Kubernetes applies
egress policy after Service DNAT, so pods dialling the kubernetes Service
are matched on the API server's own port: 6443, on a hosted cluster too
(oc get endpoints kubernetes -n default).
*/}}
{{- define "namespace-guardrails.apiAndDns" -}}
- ports:
    - {protocol: TCP, port: 6443}
- ports:
    - {protocol: UDP, port: 53}
    - {protocol: TCP, port: 53}
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: openshift-dns
  ports:
    - {protocol: UDP, port: 5353}
    - {protocol: TCP, port: 5353}
{{- end -}}
