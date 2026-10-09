{{- define "hosted-cluster-kubevirt.clusterName" -}}
{{- required "clusterName must be set" .Values.clusterName -}}
{{- end -}}

{{- define "hosted-cluster-kubevirt.baseDomain" -}}
{{- required "baseDomain must be set" .Values.baseDomain -}}
{{- end -}}
