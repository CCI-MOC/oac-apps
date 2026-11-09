{{/*
The overview dashboard every project Grafana starts with, provisioned as a
file.
*/}}
{{- define "user-projects.grafana.overviewDashboard" -}}
{
  "title": "Project overview",
  {{- /* Grafana caps a dashboard uid at 40 characters, and
         "project-<name>-overview" would pass that at 24 characters of
         project name. A hash keeps it fixed at 24 and stable across
         renders, so ArgoCD does not recreate the dashboard. */}}
  "uid": "project-{{ .name | sha256sum | trunc 16 }}-ovw",
  "time": {"from": "now-6h", "to": "now"},
  "panels": [
    {
      "type": "timeseries",
      "title": "CPU usage by pod",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
      "targets": [
        {
          "expr": "sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"project-{{ .name }}\", container!=\"\"}[5m]))",
          "legendFormat": "{{`{{pod}}`}}"
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Memory usage by pod",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
      "targets": [
        {
          "expr": "sum by (pod) (container_memory_working_set_bytes{namespace=\"project-{{ .name }}\", container!=\"\"})",
          "legendFormat": "{{`{{pod}}`}}"
        }
      ]
    }
  ]
}
{{- end }}

{{/*
The oauth-proxy container in front of each project Grafana, the only way a
person reaches it. Called with a dict: the project as
.p and the root context as .root.
*/}}
{{- define "user-projects.grafana.proxyContainer" -}}
- name: oauth-proxy
  image: {{ .root.Values.defaultGrafana.oauthProxyImage | quote }}
  ports:
    - containerPort: 8443
      name: https
  args:
    - --https-address=:8443
    - --provider=openshift
    - --upstream=http://localhost:3000
    - --tls-cert=/etc/tls/private/tls.crt
    - --tls-key=/etc/tls/private/tls.key
    # The service account is the OAuth client, so its own token is
    # the client secret and no separate one has to exist. This is
    # the flag that arranges it, together with the redirect
    # annotation on the service account above.
    - --openshift-service-account=grafana-sa
    # Read from a file rather than passed on the command line. The
    # value used to be a hash of the project name, which is public,
    # so the signing key could be recomputed by anyone and a forged
    # cookie would walk straight past the SAR below: that check runs
    # at login, an existing cookie is only verified against this key.
    # The secret is generated once by external-secrets, see
    # grafana-cookie-secret.yaml, so it stays stable across syncs.
    - --cookie-secret-file=/etc/grafana-cookie/key
    # The default session lasts seven days, so this shortens it.
    # The SAR below runs once, at code redemption. A refresh only
    # revalidates the token against the API server, it does not run
    # the SAR again, so removing somebody from the project group
    # takes effect when the cookie expires and not before. That is
    # why the expiry is short rather than the refresh frequent.
    - --cookie-expire=30m
    - --cookie-refresh=10m
    # The proxy sends Authorization: Basic <user>: upstream by
    # default, which Grafana 11.3 reads as a login attempt instead
    # of letting the anonymous Viewer through.
    - --pass-basic-auth=false
    # This is the one that gates the browser. A person arriving at
    # the route logs in through OAuth, and the proxy then checks
    # this review before handing out a session cookie. Without it
    # any authenticated cluster user could open this Grafana.
    - '--openshift-sar={"namespace": "project-{{ .p.name }}", "resource": "services", "verb": "get"}'
    # And this one gates requests that arrive with a bearer token
    # instead of a cookie, which the SAR above never sees. Same
    # namespace, so both paths are scoped to this project.
    #
    # Not the same check the datasource goes through, though. The
    # docs only say 9092 needs a binding to the view role in the
    # project, and view covers this "get services" too, which is why
    # one RoleBinding is enough. What 9092 asks for underneath is
    # "get pods" in metrics.k8s.io, read off the kube-rbac-proxy
    # config the monitoring operator ships, not from any doc.
    - '--openshift-delegate-urls={"/": {"namespace": "project-{{ .p.name }}", "resource": "services", "verb": "get"}}'
  resources:
    # Without this the project's own LimitRange defaults the sidecar
    # to 1 CPU and 2Gi, which quietly eats the quota it is meant to
    # be cheap against.
    {{- toYaml .root.Values.defaultGrafana.proxyResources | nindent 4 }}
  volumeMounts:
    - name: grafana-tls
      mountPath: /etc/tls/private
    - name: grafana-cookie
      mountPath: /etc/grafana-cookie
      readOnly: true
{{- end }}
