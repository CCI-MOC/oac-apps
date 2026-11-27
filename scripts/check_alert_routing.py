#!/usr/bin/env python3
"""Reject alert rules that the Alertmanager config would silently drop.

The Alertmanager route in charts/acm-observability is opt-in: its default
receiver has no configuration, so an alert whose name matches no route is
discarded without any error. Rules and routes live in separate templates,
so a rule group added without its route fails silently in production.

This renders both templates and checks every alert name in
thanos-ruler-custom-rules against the route matchers, so the check can
never drift from what Alertmanager would actually do.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CHART = REPO_ROOT / "charts" / "acm-observability"
RULES_CONFIGMAP = "thanos-ruler-custom-rules"
RULES_KEY = "custom_rules.yaml"
ALERTMANAGER_SECRET = "alertmanager-config"
ALERTMANAGER_KEY = "alertmanager.yaml"


def render() -> list[dict]:
    """Render the chart with both features on, as compliant-dev-infra runs it."""
    out = subprocess.run(
        [
            "helm", "template", "acm-observability", str(CHART),
            "--set", "alertmanager.enabled=true",
            "--set", "customRules.enabled=true",
        ],
        capture_output=True, text=True, check=True,
    ).stdout
    return [d for d in yaml.safe_load_all(out) if d]


def alert_names(docs: list[dict]) -> list[str]:
    for doc in docs:
        if doc.get("metadata", {}).get("name") != RULES_CONFIGMAP:
            continue
        rules = yaml.safe_load(doc["data"][RULES_KEY])
        return [
            rule["alert"]
            for group in rules["groups"]
            for rule in group["rules"]
            if "alert" in rule
        ]
    return []


def route_matchers(docs: list[dict]) -> list[re.Pattern[str]]:
    """Alertname patterns of every route, as anchored regexes.

    Alertmanager anchors =~ matchers, and treats = as a literal name.
    """
    for doc in docs:
        if doc.get("spec", {}).get("target", {}).get("name") != ALERTMANAGER_SECRET:
            continue
        config = yaml.safe_load(
            doc["spec"]["target"]["template"]["data"][ALERTMANAGER_KEY]
        )
        patterns = []
        for route in config["route"].get("routes", []):
            for matcher in route.get("matchers", []):
                name, op, value = matcher.partition("=~")
                if not op:
                    name, op, value = matcher.partition("=")
                    value = re.escape(value.strip().strip('"'))
                else:
                    value = value.strip().strip('"')
                if name.strip() == "alertname":
                    patterns.append(re.compile(f"^(?:{value})$"))
        return patterns
    return []


def main() -> int:
    docs = render()
    names = alert_names(docs)
    if not names:
        print(f"no alerts found in {RULES_CONFIGMAP}", file=sys.stderr)
        return 1

    matchers = route_matchers(docs)
    unrouted = [n for n in names if not any(m.match(n) for m in matchers)]

    if unrouted:
        print(
            f"{len(unrouted)} of {len(names)} alerts match no route and would be "
            f"dropped by the default receiver:",
            file=sys.stderr,
        )
        for name in unrouted:
            print(f"  {name}", file=sys.stderr)
        return 1

    print(f"all {len(names)} alerts are routed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
