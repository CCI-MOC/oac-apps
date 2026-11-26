{{- /*
The operator's namespace. .Values.namespaceLabels, a map, is rendered as its
labels; several operators need openshift.io/cluster-monitoring: "true" there,
because they ship ServiceMonitors written for platform monitoring (a bearer
token file and that Prometheus's certificate paths) and the platform
Prometheus reads only namespaces carrying the label. Without it the monitors
fall to user workload monitoring, which refuses any ServiceMonitor that
reads the filesystem, and the metrics are collected nowhere while the
namespace looks monitored (MOC-issues #834).
*/}}
{{- define "operator-library.namespace" -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespace }}
  {{- with .Values.namespaceLabels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec: {}
{{- end -}}

{{- define "operator-library.operatorgroup" -}}
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: {{ .Values.namespace }}
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
{{- if .Values.operatorgroup.targetNamespaces }}
spec:
  targetNamespaces:
    - {{ .Values.namespace }}
{{- else }}
spec: {}
{{- end }}
{{- end -}}

{{- define "operator-library.subscription" -}}
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: {{ .Values.subscription.name }}
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  channel: {{ .Values.subscription.channel }}
  name: {{ .Values.subscription.name }}
  source: {{ .Values.subscription.source }}
  sourceNamespace: {{ .Values.subscription.sourceNamespace }}
  installPlanApproval: {{ .Values.subscription.installPlanApproval }}
{{- with .Values.subscription.config }}
  config:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- end -}}
