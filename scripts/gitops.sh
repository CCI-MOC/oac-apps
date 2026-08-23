#!/bin/sh

# Install this as `gitops` in ~/bin and use it in preference to `argocd`.

exec argocd --port-forward --port-forward-namespace openshift-gitops "$@"
