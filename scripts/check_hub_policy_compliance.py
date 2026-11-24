#!/usr/bin/env python3
"""Reject HostedClusters/NodePools that a compliant hub's own admission
policy would reject, before they land in the repo.

A hub is compliant when hosted-clusters/<hub>/compliance.yaml exists
(see charts/hosted-cluster-compliance). This renders the real
ValidatingAdmissionPolicy CEL expressions from charts/compliance-hub-policy
and evaluates them against what ArgoCD would actually apply for every
cluster on a compliant hub, so the check can never drift from what the
hub's own webhook enforces.
"""

from __future__ import annotations

import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, TypedDict, cast

import celpy
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
HOSTED_CLUSTERS_DIR = REPO_ROOT / "hosted-clusters"
POLICY_CHART = REPO_ROOT / "charts" / "compliance-hub-policy"
HOSTED_CLUSTER_CHART = REPO_ROOT / "charts" / "hosted-cluster"

# Resource name each Kind this script can render is admitted as. A policy
# that gates a Kind not listed here (e.g. StorageClass) is simply never
# matched: there is nothing rendered of that kind to check yet.
KIND_TO_RESOURCE = {
    "HostedCluster": "hostedclusters",
    "NodePool": "nodepools",
}


class Metadata(TypedDict, total=False):
    name: str


class Manifest(TypedDict):
    kind: str
    metadata: Metadata
    spec: dict[str, Any]


@dataclass
class Policy:
    name: str
    resources: set[str]
    validations: list[tuple[str, str]]  # (expression, message)


@dataclass
class Violation:
    hub: str
    cluster: str
    kind: str
    name: str
    policy: str
    message: str


def helm_template(*args: str) -> list[Manifest]:
    result = subprocess.run(
        ["helm", "template", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"helm template {' '.join(args)} failed:\n{result.stderr}")
    return [cast(Manifest, doc) for doc in yaml.safe_load_all(result.stdout) if doc]


def load_policies(chart: Path) -> list[Policy]:
    policies = []
    for doc in helm_template("compliance-hub-policy", str(chart)):
        if doc["kind"] != "ValidatingAdmissionPolicy":
            continue
        resources = {
            resource
            for rule in doc["spec"]["matchConstraints"]["resourceRules"]
            for resource in rule["resources"]
        }
        validations = [
            (validation["expression"], validation.get("message", ""))
            for validation in doc["spec"]["validations"]
        ]
        policies.append(Policy(doc["metadata"]["name"], resources, validations))
    return policies


def discover_compliant_hubs(hosted_clusters_dir: Path) -> list[Path]:
    if not hosted_clusters_dir.is_dir():
        return []
    return sorted(
        hub
        for hub in hosted_clusters_dir.iterdir()
        if hub.is_dir() and (hub / "compliance.yaml").is_file()
    )


def discover_clusters(hub: Path) -> list[Path]:
    return sorted(
        cluster
        for cluster in hub.iterdir()
        if cluster.is_dir() and (cluster / "values.yaml").is_file()
    )


def render_cluster(cluster: Path) -> list[Manifest]:
    hub = cluster.parent
    return helm_template(
        cluster.name,
        str(HOSTED_CLUSTER_CHART),
        "-f",
        str(hub / "values.yaml"),
        "-f",
        str(cluster / "values.yaml"),
    )


def evaluate_policies(
    policies: list[Policy], manifests: list[Manifest], hub: str, cluster: str
) -> list[Violation]:
    env = celpy.Environment()
    programs: dict[str, celpy.Runner] = {}

    def program_for(expression: str) -> celpy.Runner:
        if expression not in programs:
            programs[expression] = env.program(env.compile(expression))
        return programs[expression]

    violations = []
    for manifest in manifests:
        kind = manifest["kind"]
        resource = KIND_TO_RESOURCE.get(kind)
        if resource is None:
            continue
        name = manifest["metadata"].get("name", "<unknown>")
        activation = {
            "object": celpy.json_to_cel(dict(manifest)),
            "request": celpy.json_to_cel({"resource": {"resource": resource}}),
        }
        for policy in policies:
            if resource not in policy.resources:
                continue
            for expression, message in policy.validations:
                if not bool(program_for(expression).evaluate(activation)):
                    violations.append(
                        Violation(hub, cluster, kind, name, policy.name, message)
                    )
    return violations


def main() -> int:
    policies = load_policies(POLICY_CHART)

    violations: list[Violation] = []
    for hub in discover_compliant_hubs(HOSTED_CLUSTERS_DIR):
        for cluster in discover_clusters(hub):
            manifests = render_cluster(cluster)
            violations.extend(
                evaluate_policies(policies, manifests, hub.name, cluster.name)
            )

    if violations:
        print("Non-compliant resources found:", file=sys.stderr)
        for violation in violations:
            print(
                f"  {violation.hub}/{violation.cluster}: "
                f"{violation.kind} {violation.name} violates "
                f"{violation.policy}: {violation.message}",
                file=sys.stderr,
            )
        return 1

    print("All hosted clusters on compliant hubs pass compliance-hub-policy.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
