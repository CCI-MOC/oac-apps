{{- define "cluster-config.validate-issuer-kind" -}}
{{- $allowed := list "ClusterIssuer" "Issuer" -}}
{{- if not (has .Values.certificates.issuer_kind $allowed) -}}
{{- fail (printf "certificates.issuer_kind must be one of %s, got: %s" ($allowed | join ", ") .Values.certificates.issuer_kind) -}}
{{- end -}}
{{- end -}}
