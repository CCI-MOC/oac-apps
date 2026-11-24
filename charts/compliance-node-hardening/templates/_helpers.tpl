{{/*
Encode text as a base64 Ignition data: URL. Percent-encoding by hand missed
characters MCO expects escaped, so base64 avoids the mismatch entirely.
*/}}
{{- define "cnh.dataURL" -}}
data:;base64,{{ . | b64enc }}
{{- end -}}

{{/* The sshd AllowUsers drop-in as an Ignition file entry (JSON). */}}
{{- define "cnh.sshdFile" -}}
{{- $s := .Values.sshdAllowUsers -}}
{{- $body := printf "%s\nAllowUsers %s\n" $s.header (join " " $s.users) -}}
{{- dict "path" (printf "/etc/ssh/sshd_config.d/%s" $s.fileName) "mode" 384 "overwrite" true "contents" (dict "source" (include "cnh.dataURL" $body)) | toJson -}}
{{- end -}}

{{/*
Files under files/ write storage file contents as a literal string, not the
Ignition {source: data:,...} form, so the rule text is readable instead of
percent-encoded. Expand any such strings back into that form in place.
*/}}
{{- define "cnh.expandFileContents" -}}
{{- $spec := . -}}
{{- $storage := ($spec.config).storage -}}
{{- if $storage -}}
{{- range $storage.files -}}
{{- if kindIs "string" .contents -}}
{{- $_ := set . "contents" (dict "source" (include "cnh.dataURL" .contents)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $spec | toJson -}}
{{- end -}}

{{/*
Every rule to render for a role, as a JSON list of {name, spec}. Honours
excludeRules. The NodePool ConfigMap asks for "worker" only.
*/}}
{{- define "cnh.rules" -}}
{{- $root := index . 0 -}}
{{- $role := index . 1 -}}
{{- $out := list -}}
{{- range $root.Values.profiles -}}
{{- $p := . -}}
{{- if has $role $p.roles -}}
{{- range $path, $_ := $root.Files.Glob (printf "files/%s/*.yaml" $p.dir) -}}
{{- $rule := base $path | trimSuffix ".yaml" -}}
{{- if not (has $rule $root.Values.excludeRules) -}}
{{- $name := ternary (printf "%s-%s-%s" $p.namePrefix $role $rule) (printf "%s-%s" $p.namePrefix $rule) $p.roleInName -}}
{{- $spec := include "cnh.expandFileContents" ($root.Files.Get $path | fromYaml) | fromJson -}}
{{- $out = append $out (dict "name" $name "spec" $spec) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}
