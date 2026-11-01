{{/* Egress rules for the API server and cluster DNS. */}}
{{- define "guardrails.apiAndDns" -}}
- ports:
    - {protocol: TCP, port: {{ .Values.apiServerPort }}}
- ports:
    - {protocol: UDP, port: 53}
    - {protocol: TCP, port: 53}
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: openshift-dns
  ports:
    - {protocol: UDP, port: 5353}
    - {protocol: TCP, port: 5353}
{{- end -}}
