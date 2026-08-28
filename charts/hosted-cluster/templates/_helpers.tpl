{{/*
Return the hub-level base domain, failing if it has not been set.
baseDomain is a per-hub value with no safe default; it must be supplied via a
hub-level values file (hosted-clusters/<hub>/values.yaml).
*/}}
{{- define "hosted-cluster.baseDomain" -}}
{{- required "baseDomain must be set (supply it in the hub-level values file hosted-clusters/<hub>/values.yaml)" .Values.baseDomain -}}
{{- end -}}

{{/*
Return the hub's management cluster name, failing if it has not been set.
managementCluster is a per-hub value with no safe default; it must be supplied
via a hub-level values file (hosted-clusters/<hub>/values.yaml).
*/}}
{{- define "hosted-cluster.managementCluster" -}}
{{- required "managementCluster must be set (supply it in the hub-level values file hosted-clusters/<hub>/values.yaml)" .Values.managementCluster -}}
{{- end -}}

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

{{/*
Service metadata shared across templates.
*/}}
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

{{/*
Derive the OAuth server hostname from the root context (.).
Mirrors the derivation used for the OAuthServer service publishing strategy.
*/}}
{{- define "hosted-cluster.oauthHostname" -}}
{{- $clusterName := required "clusterName is required" .Values.clusterName -}}
{{- $defaults := include "hosted-cluster.serviceDefaults" . | fromYaml -}}
{{- $svcDef := index $defaults "OAuthServer" -}}
{{- $serviceConfig := dig "OAuthServer" dict .Values.services -}}
{{- include "hosted-cluster.serviceHostname" (dict "serviceConfig" $serviceConfig "prefix" $svcDef.prefix "facing" $svcDef.facing "clusterName" $clusterName "ctx" .) -}}
{{- end -}}
