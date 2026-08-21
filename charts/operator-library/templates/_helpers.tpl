{{- define "operator-library.namespace" -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespace }}
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
{{- end -}}
