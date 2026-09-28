{{- define "spoke-cluster.clusterName" -}}
{{- required "clusterName must be set" .Values.clusterName -}}
{{- end -}}

{{- define "spoke-cluster.namespace" -}}
{{- required "namespace must be set" .Values.namespace -}}
{{- end -}}

{{- define "spoke-cluster.baseDomain" -}}
{{- required "baseDomain must be set" .Values.baseDomain -}}
{{- end -}}

{{- define "spoke-cluster.releaseImage" -}}
{{- required "release.image must be set" .Values.release.image -}}
{{- end -}}

{{- define "spoke-cluster.releaseName" -}}
{{- required "release.name must be set" .Values.release.name -}}
{{- end -}}
