{{- define "cluster-config.validate-issuer-kind" -}}
{{- $allowed := list "ClusterIssuer" "Issuer" -}}
{{- if not (has .Values.certificate.issuer_kind $allowed) -}}
{{- fail (printf "certificate.issuer_kind must be one of %s, got: %s" ($allowed | join ", ") .Values.certificate.issuer_kind) -}}
{{- end -}}
{{- end -}}
