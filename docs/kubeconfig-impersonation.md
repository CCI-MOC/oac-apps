# Adding impersonation to your kubeconfig

Some operations require you to act as another identity (for example
`system:admin`). Kubernetes calls this impersonation, and in the past we have
utilized this feature with the `--as <user>` command line option to `kubectl`
or `oc`. This works fine for simple command line invocation, but can be
problematic when you're relying on tooling (like a collection of ansible
playbooks) that does not natively offer support for impersonation.

In these cases, we can enable impersonation via the kubernetes client
configuration file by adding an `as:` field to the appropriate `user` entry in
your kubeconfig.

The tricky part is that a kubeconfig often contains many clusters and many
users, and it is easy to change the wrong block. This document shows how to add
a second user and a second context for the same cluster: one impersonating,
one not. You can then switch between them with a single command whenever you
need to, and your original configuration is never modified.

## Impersonation lives on the user

Impersonation attaches to a **user**, not to a cluster or a context. Your
currently selected context tells you which user is active, so you never have to
guess which block to work with. A context is simply a named pairing of a
cluster and a user, which is why we can point a new context at an impersonating
copy of your user while leaving the original untouched.

## 1. Identify your current context

Run:

```bash
oc config view --minify
```

The `--minify` flag collapses the output to only the currently active context,
cluster, and user. Note three names from the output — you will need them below:

```yaml
contexts:
- context:
    cluster: mycluster            # the cluster name
    user: you@youremail.com       # the user name
  name: mycluster                 # the context name
```

## 2. Add an impersonating copy of your user

Open your kubeconfig (`~/.kube/config` by default, or whatever `KUBECONFIG`
points to) and find the `users:` entry whose `name:` matches the user from the
previous step. Copy that whole entry, give the copy a new name, and add an
`as:` line to the copy:

```yaml
users:
- name: you@youremail.com         # original, unchanged
  user:
    token: sha256~...
- name: you@youremail.com/admin   # the new copy
  user:
    token: sha256~...
    as: system:admin              # <-- the only added line
```

## 3. Create a context that uses the impersonating user

Unlike the user entry, the new context *can* be created from the command line.
Point it at the same cluster from step 1 and the new user from step 2:

```bash
oc config set-context mycluster-admin \
  --cluster=mycluster \
  --user=you@youremail.com/admin
```

## 4. Switch between impersonated and normal

Use `oc config use-context` to move between the two:

```bash
oc config use-context mycluster-admin   # act as system:admin
oc config use-context mycluster         # back to your normal identity
```

List everything you can switch between with:

```bash
oc config get-contexts
```

## 5. Verify

After switching to the impersonating context, confirm the `as:` field is active
and check who the cluster sees you as:

```bash
oc config view --minify      # 'as: system:admin' should appear under the user
oc auth whoami               # should report system:admin
```
