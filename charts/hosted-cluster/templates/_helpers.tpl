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
Service metadata shared across templates.
*/}}
{{- define "hosted-cluster.serviceDefaults" -}}
APIServer:
  prefix: api
  defaultType: NodePort
  k8sServiceName: kube-apiserver
Ignition:
  prefix: ignition
  defaultType: Route
  k8sServiceName: ignition-server
Konnectivity:
  prefix: konnectivity
  defaultType: Route
  k8sServiceName: konnectivity-server
OAuthServer:
  prefix: oauth
  defaultType: Route
  k8sServiceName: oauth-openshift
OIDC:
  prefix: ""
  defaultType: Route
  k8sServiceName: ""
{{- end -}}

{{/*
Derive the hostname for a service.
Expects a dict with keys: serviceConfig, prefix, clusterName, baseDomain.
Returns the hostname string, or empty string if none can be derived.
*/}}
{{- define "hosted-cluster.serviceHostname" -}}
{{- $hostname := dig "hostname" "" .serviceConfig -}}
{{- if not $hostname -}}
  {{- if .prefix -}}
    {{- $hostname = printf "%s-%s.%s" .prefix .clusterName .baseDomain -}}
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
{{- include "hosted-cluster.serviceHostname" (dict "serviceConfig" $serviceConfig "prefix" $svcDef.prefix "clusterName" $clusterName "baseDomain" (include "hosted-cluster.baseDomain" .)) -}}
{{- end -}}
