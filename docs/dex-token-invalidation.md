# ArgoCD SSO tokens are invalidated every ~40 minutes

## Symptom

After authenticating to ArgoCD with `argocd login --sso` (in `--port-forward` mode
against the operator-managed instance in `openshift-gitops`), the CLI session stops
working well before the token's stated expiration. A command that succeeded minutes
earlier fails with:

```
rpc error: code = Unauthenticated desc = invalid session: failed to verify the token
```

and the `openshift-gitops-server` pod logs:

```
Failed to verify session token: failed to verify provider token: token verification
failed for all audiences: error for aud "argo-cd-cli": failed to verify signature:
failed to verify id token signature
```

The token itself is *not* expired. Decoding the stored `auth-token`
(`~/.config/argocd/config`) shows a full 24-hour window (`exp - iat == 86400`). The
failure is signature verification, not expiry.

## Root cause

The `id_token` is signed by the bundled Dex server, and ArgoCD validates it against
Dex's JWKS. Dex is being **restarted on a fixed ~40-minute cadence**, and because its
key storage is in-memory, every restart regenerates the signing keys. Any `id_token`
issued before a restart can no longer be verified, so the user is effectively logged
out at the next restart boundary — regardless of the token's 24-hour lifetime.

The `openshift-gitops-server` log shows the trigger, repeating every 40m12s:

```
time="...T20:31:00Z" level=info msg="dex config modified. restarting"
```

### Why the Dex config changes every 40m12s

It is not `argocd-cm` that changes — it is the Dex OAuth client secret in the
`argocd-secret` Secret (key `oidc.dex.clientSecret`).

With `spec.sso.dex.openShiftOAuth: true`, the OpenShift GitOps operator mints that
client secret as a **bound ServiceAccount token** (TokenRequest API) for the
`*-argocd-dex-server` ServiceAccount, and rotates it:

- token lifetime: `ArgoCDDexServerTokenExpirySecs = 3600` (1 hour)
- renewed once less than 33% of the lifetime remains
  (`ArgoCDDexServerTokenRenewalThresholdPercent = 33`)

So renewal fires at 67% elapsed: `3600 × 0.67 = 2412 s = 40m12s`, matching the
observed cadence exactly. On the affected cluster the `argocd-secret` update
timestamp matched the `"dex config modified. restarting"` event to the second.

The `dex.config` in `argocd-cm` stores the literal placeholder
`$oidc.dex.clientSecret`. The `argocd-dex rundex` wrapper watches both `argocd-cm`
and `argocd-secret`, substitutes the live secret value, and compares the *resolved*
config. When the operator rotates the token, the resolved config changes, the wrapper
logs `"dex config modified. restarting"`, and Dex restarts.

Relevant source (`argoproj-labs/argocd-operator` and `argoproj/argo-cd`):

- `controllers/argocd/dex.go` — `getDexOAuthClientSecret`, `getOpenShiftDexConfig`
- `controllers/argocd/secret.go` — `reconcileArgoSecret`
- `common/defaults.go` — token expiry / renewal-threshold constants
- argo-cd `util/dex/config.go` — `GenerateDexConfigYAML`, `ReplaceMapSecrets`

Related upstream issues: redhat-developer/gitops-operator#349, argoproj/argo-cd#9091.

## Persistent Dex key storage is not achievable

The obvious mitigation — give Dex persistent key storage so signing keys survive
restarts — is not possible with operator-managed Dex. The Dex storage backend is
hardcoded to in-memory in argo-cd's `util/dex/config.go` (`GenerateDexConfigYAML`
sets `storage: {type: memory}` unconditionally). Although the operator does merge
`spec.sso.dex.config` with the generated config, any `storage:` stanza is stripped
and replaced before Dex starts, and there is no operator CR field for it.

## Workaround

For CLI and automation workflows (the `--port-forward` use case), do not rely on SSO
tokens. Use a **local-account API token** instead. Local tokens are signed with the
server's own `server.secretkey`, validated entirely inside `argocd-server`, and never
touch Dex — so they are immune to the Dex restarts.

1. Enable a local account in `argocd-cm`:

    ```yaml
    data:
      accounts.automation: apiKey, login
    ```

2. Grant it RBAC in `argocd-rbac-cm`, for example:

    ```
    p, role:automation, applications, *, */*, allow
    g, automation, role:automation
    ```

3. Generate a token (`--expires-in 0` never expires):

    ```
    argocd --port-forward --port-forward-namespace openshift-gitops \
      account generate-token --account automation --expires-in 0
    ```

For durable *interactive* SSO sessions, the alternative is to move off
operator-managed Dex to an external OIDC provider (e.g. Keycloak / RH-SSO) whose
signing keys persist across restarts.
