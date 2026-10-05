#!/bin/bash

# Verify the pfSense firewall / HAProxy setup of a hosted cluster, as
# described in firewall-rules.md. Run it with KUBECONFIG pointing at the
# guest cluster. The node probes use `oc debug node`, which needs
# cluster-admin (e.g. the impersonating context from
# kubeconfig-impersonation.md):
#
#   ./docs/firewall-rules.sh verify
#
# The cluster name, the external domain and the VIPs are derived from the
# current API server URL (api-external-<cluster>.<domain>) and DNS. Override
# them with CLUSTER, HCP_EXTERNAL_DOMAIN, API_VIP, INGRESS_VIP, OAUTH_VIP;
# HCP_EXTERNAL_DOMAIN is required when logged in via api-internal-*.

set -u

: "${IDLE_TEST_SECONDS:=45}"

usage() {
  echo "usage: $0 verify" >&2
  exit 2
}

resolve() {
  getent hosts "$1" | awk '{print $1; exit}'
}

fail=0
ok() { printf '  %-50s OK\n' "$1"; }
nok() { printf '  %-50s FAIL %s\n' "$1" "$2"; fail=1; }

verify() {
  local server
  server=$(oc whoami --show-server)
  if [ -z "${CLUSTER:-}" ]; then
    CLUSTER=$(sed -nE 's#^https://api-(external|internal)-([^.]+)\..*#\2#p' <<< "$server")
  fi
  if [ -z "${HCP_EXTERNAL_DOMAIN:-}" ]; then
    HCP_EXTERNAL_DOMAIN=$(sed -nE 's#^https://api-external-[^.]+\.([^:/]+).*#\1#p' <<< "$server")
  fi
  if [ -z "$CLUSTER" ] || [ -z "$HCP_EXTERNAL_DOMAIN" ]; then
    echo "cannot derive cluster name / external domain from $server," >&2
    echo "set CLUSTER and HCP_EXTERNAL_DOMAIN" >&2
    exit 1
  fi

  local api_host="api-external-${CLUSTER}.${HCP_EXTERNAL_DOMAIN}"
  local oauth_host="oauth-${CLUSTER}.${HCP_EXTERNAL_DOMAIN}"
  local apps_host="console-openshift-console.apps.${CLUSTER}.${HCP_EXTERNAL_DOMAIN}"
  # API and ingress can share one VIP (prod) or use two (dev).
  : "${API_VIP:=$(resolve "$api_host")}"
  : "${INGRESS_VIP:=$(resolve "$apps_host")}"
  : "${OAUTH_VIP:=$(resolve "$oauth_host")}"

  echo "cluster:     $CLUSTER"
  echo "API VIP:     ${API_VIP:-?} ($api_host)"
  echo "ingress VIP: ${INGRESS_VIP:-?} ($apps_host)"
  echo "OAuth VIP:   ${OAUTH_VIP:-?} ($oauth_host)"
  if [ -z "$API_VIP" ] || [ -z "$INGRESS_VIP" ] || [ -z "$OAUTH_VIP" ]; then
    echo "cannot resolve VIPs, set API_VIP / INGRESS_VIP / OAUTH_VIP" >&2
    exit 1
  fi

  local node
  node=$(oc get nodes -l node-role.kubernetes.io/worker -o name | head -1)
  echo
  echo "From data-plane node ${node#node/}:"

  # One debug pod for all probes; each line of output is "<check> <result>".
  local probes
  probes=$(oc debug -q "$node" -- chroot /host bash -c "
    for p in $API_VIP:6443 $INGRESS_VIP:80 $INGRESS_VIP:443 $OAUTH_VIP:443; do
      if timeout 5 bash -c \"</dev/tcp/\${p%:*}/\${p#*:}\" 2>/dev/null; then
        echo \"tcp:\$p ok\"
      else
        echo \"tcp:\$p fail\"
      fi
    done
    code=\$(curl -sk -o /dev/null -m 10 -w '%{http_code}' \
      --resolve $oauth_host:443:$OAUTH_VIP https://$oauth_host/healthz)
    echo \"tls:$oauth_host \$code\"
  " 2>&1)

  local check result
  while read -r check result; do
    case "$check" in
      tcp:*)
        if [ "$result" = ok ]; then ok "TCP ${check#tcp:}"; else nok "TCP ${check#tcp:}" "(no connect)"; fi
        ;;
      tls:*)
        # Any HTTP status means the TLS handshake through HAProxy worked.
        if [ "$result" != 000 ]; then ok "OAuth TLS handshake (HTTP $result)"; else nok "OAuth TLS handshake" "(no response)"; fi
        ;;
    esac
  done <<< "$probes"
  if ! grep -qE '^(tcp|tls):' <<< "$probes"; then
    nok "oc debug node (needs cluster-admin)" "$probes"
  fi

  # HAProxy timeouts: an idle watch must survive longer than the pfSense
  # default of 30s (see "Timeouts" in firewall-rules.md).
  echo
  echo "From here, via $api_host:"
  local start rc
  start=$(date +%s)
  timeout "$IDLE_TEST_SECONDS" oc --server "https://${api_host}:6443" \
    get pods -n kube-system -w >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    ok "idle watch survives ${IDLE_TEST_SECONDS}s"
  else
    nok "idle watch survives ${IDLE_TEST_SECONDS}s" "(ended after $(($(date +%s) - start))s, HAProxy timeouts?)"
  fi

  echo
  oc get clusteroperator ingress console

  return $fail
}

case "${1:-}" in
  verify) verify ;;
  *) usage ;;
esac
