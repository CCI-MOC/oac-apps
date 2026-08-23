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
