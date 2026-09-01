# Managing external resources

This document describes how to deliver third-party workloads — Helm charts
published elsewhere and Kubernetes manifests maintained in other repositories —
to a group of managed clusters, following the conventions this repository
already uses.

Cluster targeting is the same in both cases. A workload reaches a set of
clusters through an ACM `Placement` referenced by an ApplicationSet. Either
reuse an existing placement (`all-managed-clusters`, or a feature placement such
as `gpu-clusters`) or add a new one to `charts/acm-placements` via
`values/<hub>/local-cluster/acm-placements.yaml`, giving it the label selector
that identifies the target clusters.

## External Helm charts

Wrap the external chart in a local chart under `charts/`, so it keeps the same
`path: charts/<component>` and per-hub values layout every other component uses.

1. Create `charts/<component>/Chart.yaml` declaring the external chart as a
   dependency:

   ```yaml
   apiVersion: v2
   name: <component>
   version: 0.1.0
   type: application
   dependencies:
     - name: <upstream-chart>
       version: "1.2.3"
       repository: "https://charts.example.com"
   ```

2. Run `helm dependency update charts/<component>` to produce `Chart.lock`, and
   place overrides in `charts/<component>/values.yaml`.

   Values for a dependency chart must be nested under the dependency's name.
   This applies to both `charts/<component>/values.yaml` and the per-hub value
   files under `values/`. For a dependency named `<upstream-chart>`:

   ```yaml
   # charts/<component>/values.yaml
   <upstream-chart>:
     replicaCount: 3
     image:
       tag: "1.2.3"
   ```

   Any key that is not nested under `<upstream-chart>` is passed to the wrapper
   chart itself, not the dependency, and is silently ignored unless the wrapper
   consumes it.

   Commit `Chart.lock` for external charts. The repository gitignores
   `Chart.lock` by default because the in-repo `file://` library dependencies
   gain nothing from it, but an external dependency does: the lock pins the
   exact resolved version and records a `sha256` digest, so builds are
   reproducible and tamper-evident instead of re-resolving `Chart.yaml` on every
   render. Un-ignore it with a negation in `.gitignore`:

   ```gitignore
   !/charts/<component>/Chart.lock
   ```

3. Add a unit test under `charts/<component>/tests/unit/` and verify the chart
   renders with `helm template charts/<component>`.

4. Wire the component to a placement:

   - **All managed clusters:** add `- component: <component>` to the `list`
     generator in `applicationsets/templates/managed/all-managed-clusters.yaml`.
   - **A label group:** add `- component: <component>` to the matching
     ApplicationSet's `list` generator, or create a new ApplicationSet from the
     `gpu-clusters.yaml` template pointing at the appropriate placement.

5. Optionally add per-hub or per-cluster overrides at
   `values/<hub>/<component>.yaml` and `values/<hub>/<cluster>/<component>.yaml`,
   nesting their keys under the dependency name as in step 2. Both files are
   optional because the templates set `ignoreMissingValueFiles: true`.

## External Kubernetes repositories

For a project maintained as raw manifests or a kustomize base in another
repository, add a local kustomize overlay under `kustomize/` that references the
external project as a remote base. This anchors everything in this repository,
pins the upstream version, and provides a place to patch without forking.

1. Create `kustomize/<project>/kustomization.yaml`:

   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - github.com/some-org/some-project/config/default?ref=v1.4.0
   namespace: <namespace>
   patches: []
   images: []
   ```

   Pin the `?ref=` to a tag or commit, and express any changes as patches here
   rather than forking upstream.

2. Verify it renders with `oc kustomize kustomize/<project>`.

3. Create a dedicated ApplicationSet at
   `applicationsets/templates/managed/<project>.yaml`. Use the same placement
   generator as the other managed ApplicationSets, but a kustomize source with
   no `helm:` block:

   ```yaml
   {{- $hub := required "hubName must be set" .Values.hubName }}
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: <project>
     namespace: openshift-gitops
   spec:
     generators:
       - clusterDecisionResource:
           configMapRef: acm-placement
           labelSelector:
             matchLabels:
               cluster.open-cluster-management.io/placement: <placement-name>
           requeueAfterSeconds: 180
     template:
       metadata:
         name: "{{`{{name}}`}}-<project>"
       spec:
         project: default
         source:
           repoURL: https://github.com/CCI-MOC/oac-apps.git
           targetRevision: main
           path: "kustomize/<project>"
         destination:
           server: "{{`{{server}}`}}"
           namespace: <namespace>
         syncPolicy:
           automated:
             prune: true
             selfHeal: true
           syncOptions:
             - CreateNamespace=true
           retry:
             limit: 5
             backoff:
               duration: 30s
               factor: 2
               maxDuration: 10m
   ```

Kustomize has no equivalent of `ignoreMissingValueFiles`: a referenced overlay
path that does not exist fails the sync. Keep the overlay uniform across the
target clusters, or create an overlay directory for every cluster you target.
