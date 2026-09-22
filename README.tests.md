# OAC Apps Integrated Testing

There are two kinds of tests:

| Kind            | Needs a cluster? | Checks                         |
| --------------- | ---------------- | ------------------------------ |
| Helm unit tests | No               | What a chart _renders_         |
| Chainsaw tests  | Yes              | What is _running_ on a cluster |

## Helm unit tests

Tests live in `<chart>/tests/unit/*_test.yaml`. They run
[helm-unittest](https://github.com/helm-unittest/helm-unittest). They are
fast, offline, and run on every pull request.

### What can be tested

Helm renders the chart's templates with some values, and the test asserts
on the resulting manifests. For example:

- Does this value produce the expected resource?
- Is a field set correctly (or left out)?
- Does a missing required value fail the render?
- Does a feature flag turn a resource on or off?

This tests the _YAML we generate_. It does not tell you whether a cluster
accepts it or whether it works.

### Run tests for one chart

```
helm unittest -f 'tests/unit/*_test.yaml' charts/portworx
```

The `-f` is needed because our tests live in `tests/unit/`, not the
helm-unittest default of `tests/`.

The same works for `applicationsets/` and `bootstrap/`.

### Run all tests

```
./scripts/helm-unittest-all.sh
```

### One-time setup

You need to install the `helm-unittest` plugin before you can run the Helm
unit tests:

```
helm plugin install --verify=false https://github.com/helm-unittest/helm-unittest
```

### Learn more

- Docs:
  https://github.com/helm-unittest/helm-unittest/blob/main/DOCUMENT.md
- Examples: any file under `charts/*/tests/unit/`, e.g.
  `charts/portworx/tests/unit/storageclass_test.yaml`

## Chainsaw tests

Tests live in `<chart>/tests/healthcheck/` and `<chart>/tests/functional/`.
Each test directory has a `chainsaw-test.yaml`. They run
[Chainsaw](https://kyverno.github.io/chainsaw/) against a **real cluster**,
whichever one your `KUBECONFIG` points at.

There are two kinds, identified by a label on the test:

|                          | Healthcheck                    | Functional                      |
| ------------------------ | ------------------------------ | ------------------------------- |
| Label                    | `healthcheck: "true"`          | `functional: "true"`            |
| Reads existing resources | Yes                            | Yes                             |
| Creates resources        | **No**                         | **Yes** (cleaned up afterwards) |
| Question it answers      | "Is it installed and healthy?" | "Does it actually work?"        |

### Healthchecks

Read-only. They assert on the state of resources that already exist:
Deployments are available, operators have succeeded, nodes are ready.
Nothing is created or changed.

Example: `charts/cert-manager/tests/healthcheck/`

### Functional tests

They create resources and check what the cluster does with them. For
example, the cert-manager test creates a `Certificate` and waits for a
`Secret` to appear. The storage tests create a PVC and a pod that mounts
it. The tenant network tests create namespaces and pods, then check what
can talk to what.

Chainsaw deletes what it created when the test ends.

These tests are generally safe to run, but they take longer than the health
checks. If you interrupt a running test you will need to manually clean up
any resources it created.

Example: `charts/cert-manager/tests/functional/`

### Run tests for one chart

Healthchecks:

```
chainsaw test --selector healthcheck=true charts/cert-manager
```

Functional:

```
chainsaw test --selector functional=true charts/cert-manager
```

Both:

```
chainsaw test charts/cert-manager
```

### Run all tests

All healthchecks:

```
chainsaw test --selector healthcheck=true
```

All functional tests:

```
chainsaw test --selector functional=true
```

Heads up: this runs the tests for _every_ chart, including ones that aren't
installed on your cluster. Those will fail. Expect some red.

### Reports

The terminal output from `chainsaw test` is a little noisy. Chainsaw writes a
report in Junit format to `chainsaw-report.xml`; you can use a junit visualizer
to process that into something easier to read. Online options include:

- <https://lotterfriends.github.io/online-junit-parser/>

### Learn more

- Docs: https://kyverno.github.io/chainsaw/
- Shared building blocks: [`tests/templates/`](tests/templates/) (e.g.
  [`deployment-available.yaml`](deployment-available.yaml))
- Healthcheck example: [`charts/cert-manager/tests/healthcheck/chainsaw-test.yaml`](charts/cert-manager/tests/healthcheck/chainsaw-test.yaml)
- Functional example: [`charts/lvmcluster/tests/functional/`](charts/lvmcluster/tests/functional/)
- Cluster-wide healthchecks: [`tests/healthcheck/`](tests/healthcheck/)
