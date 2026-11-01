{{/*
Percent-encode text for an Ignition data: URL. Go's urlquery writes spaces
as "+", which RFC 2397 data URLs do not decode, so encode by hand. Covers
the characters sshd drop-ins actually contain.
*/}}
{{- define "cnh.dataURL" -}}
data:,{{ . | replace "%" "%25" | replace " " "%20" | replace "\n" "%0A" | replace "#" "%23" | replace "/" "%2F" | replace "?" "%3F" | replace "," "%2C" | replace "\"" "%22" }}
{{- end -}}

{{/* The sshd AllowUsers drop-in as an Ignition file entry (JSON). */}}
{{- define "cnh.sshdFile" -}}
{{- $s := .Values.sshdAllowUsers -}}
{{- $body := printf "%s\nAllowUsers %s\n" $s.header (join " " $s.users) -}}
{{- dict "path" (printf "/etc/ssh/sshd_config.d/%s" $s.fileName) "mode" 384 "overwrite" true "contents" (dict "source" (include "cnh.dataURL" $body)) | toJson -}}
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
{{- $out = append $out (dict "name" $name "spec" ($root.Files.Get $path | fromYaml)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}
