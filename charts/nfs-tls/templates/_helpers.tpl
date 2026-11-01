{{/* Where the trust anchors come from: "inline", "configMap" or "secret". */}}
{{- define "nfs-tls.caSource" -}}
{{- $n := 0 -}}
{{- if .Values.ca.inline }}{{ $n = add1 $n }}{{ end -}}
{{- if .Values.ca.existingConfigMap }}{{ $n = add1 $n }}{{ end -}}
{{- if .Values.ca.externalSecret.remoteKey }}{{ $n = add1 $n }}{{ end -}}
{{- if ne $n 1 }}{{ fail "set exactly one of ca.inline, ca.existingConfigMap, ca.externalSecret.remoteKey" }}{{ end -}}
{{- if .Values.ca.inline }}inline{{ else if .Values.ca.existingConfigMap }}configMap{{ else }}secret{{ end -}}
{{- end -}}
