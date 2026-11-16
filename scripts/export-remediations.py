#!/usr/bin/env python3
"""Export Compliance Operator node remediations into chart files.

Reads `oc get complianceremediation -n openshift-compliance -o json` on stdin
and writes one file per rule under charts/compliance-node-hardening/files/:

  files/<profile>/<rule>.yaml           role-neutral (rendered for every role)
  files/<profile>-master/<rule>.yaml    master-only scans (no worker twin)

Each file holds the MachineConfig `spec` the operator would have created,
with file contents as plain text; the chart encodes them again at render
time. The encoding differs from the operator's, but the files written to
the nodes are the same as on a cluster remediated by the operator.

Each file starts with a header saying what the rule is for: its title, NIST
800-53 controls, severity and rationale. --rules gives where to read them:

  --rules rules.json   `oc get rules.compliance.openshift.io -n
                       openshift-compliance -o json` from the same cluster
                       (best: matches the content the remediations came from)
  --rules DIR          a ComplianceAsCode/content checkout, at the release the
                       cluster's content image was built from

--headers-only rewrites the headers of the files already in the directory
and leaves their contents alone; it reads nothing on stdin.

The master and worker scans of a node profile normally produce identical
remediations. This script refuses to write anything if they differ, rather
than silently picking one.

By default only remediations with spec.apply == true are exported: what a
cluster that applied them actually runs. This is how the files from jetty
were made.

With --all, remediations that were not applied are exported too. The
operator creates a remediation, with its full MachineConfig, for every
failing check whether or not it is applied, so a scan-only cluster (a
compliant hub, where nothing is applied) is enough. Remediations that
cannot be used as they are, a variable to set first or a dependency not
met, are skipped with a warning. The operator only sets NeedsReview or
MissingDependencies once apply is true, so these are found by the
has-unset-variable and has-unmet-dependencies labels, which it sets either
way. Remediations in Error, and ones that are not MachineConfigs (platform
fixes, which belong in other charts), are skipped too.

Usage:
  KUBECONFIG=... oc get complianceremediation -n openshift-compliance -o json \
    | scripts/export-remediations.py [--all] [--rules SRC] charts/compliance-node-hardening/files
  scripts/export-remediations.py --headers-only --rules SRC charts/compliance-node-hardening/files
"""

import json
import os
import re
import sys
import textwrap
import urllib.parse

import yaml

SKIP_STATES = {"NeedsReview", "MissingDependencies", "Error"}
SKIP_LABELS = (
    "compliance.openshift.io/has-unset-variable",
    "compliance.openshift.io/has-unmet-dependencies",
)


class LiteralDumper(yaml.SafeDumper):
    pass


def _str_presenter(dumper, data):
    style = "|" if "\n" in data else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style=style)


LiteralDumper.add_representer(str, _str_presenter)


def decode_contents(spec):
    """Replace data: URL file contents with the plain text they decode to.

    The chart re-encodes them into Ignition's {source: data:,...} form at
    render time, so the checked-in file holds readable text instead of a
    percent-encoded blob.
    """
    files = spec.get("config", {}).get("storage", {}).get("files", [])
    for f in files:
        source = f.get("contents", {}).get("source", "")
        if source.startswith("data:,"):
            f["contents"] = urllib.parse.unquote(source[len("data:,") :])
    return spec


def rule_key(name):
    """A rule name in the form every source can be matched on."""
    name = re.sub(r"^(rhcos4|ocp4)-", "", name)
    return name.replace("-", "_").lower()


def clean(text):
    """Rationale text as one plain paragraph: no HTML, no template markup."""
    text = text.split("\n\n")[0]
    text = re.sub(r"\{\{[{%].*?[}%]\}\}?", "", text)
    text = re.sub(r"<[^>]+>", "", text)
    return " ".join(text.split()).strip(" '")


def load_rules(src):
    """rule key -> {title, nist, severity, rationale}, from a cluster's Rule
    objects (a JSON file) or a ComplianceAsCode checkout (a directory)."""
    rules = {}
    if os.path.isdir(src):
        for root, dirs, files in os.walk(src):
            dirs[:] = [d for d in dirs if d != "tests"]
            if "rule.yml" not in files:
                continue
            try:
                with open(os.path.join(root, "rule.yml")) as f:
                    # rule.yml is a Jinja template. Drop the template lines
                    # (macros and conditionals on a line of their own) and
                    # blank out inline macros, which the fields read here
                    # do not need, so that what is left parses as YAML.
                    text = "".join(
                        l for l in f if not l.lstrip().startswith(("{{{", "{{%"))
                    )
                y = yaml.safe_load(re.sub(r"\{\{\{.*?\}\}\}", "", text))
            except yaml.YAMLError:
                print(f"cannot read {root}/rule.yml", file=sys.stderr)
                continue
            nist = str((y.get("references") or {}).get("nist", ""))
            rules[rule_key(os.path.basename(root))] = {
                "title": y.get("title", ""),
                "nist": [c.strip() for c in nist.split(",") if c.strip()],
                "severity": y.get("severity", ""),
                "rationale": y.get("rationale", ""),
            }
    else:
        with open(src) as f:
            for r in json.load(f)["items"]:
                ann = r["metadata"].get("annotations", {})
                nist = ann.get("control.compliance.openshift.io/NIST-800-53", "")
                rules[rule_key(r["metadata"]["name"])] = {
                    "title": r.get("title", ""),
                    "nist": [c.strip() for c in nist.split(";") if c.strip()],
                    "severity": r.get("severity", ""),
                    "rationale": r.get("rationale", ""),
                }
    return rules


def header(d, rule, rules):
    """The comment block at the top of a chart file."""
    lines = [f"Compliance Operator remediation {d}/{rule}"]
    if rules is not None:
        # The operator numbers a rule's remediations when there is more
        # than one (sshd-set-keepalive-1); the rule itself has no number.
        info = rules.get(rule_key(rule)) or rules.get(
            rule_key(re.sub(r"-\d+$", "", rule))
        )
        if info is None:
            print(f"no rule found for {d}/{rule}; header without it", file=sys.stderr)
        else:
            lines.append(info["title"])
            meta = []
            if info["nist"]:
                meta.append("NIST 800-53: " + ", ".join(info["nist"]) + ".")
            if info["severity"]:
                meta.append(f"Severity: {info['severity']}.")
            if meta:
                lines.append(" ".join(meta))
            why = clean(info["rationale"])
            if why:
                lines += textwrap.wrap("Why: " + why, 76)
    lines.append("Generated by scripts/export-remediations.py; do not edit.")
    return "".join(f"# {l}\n" for l in lines)


def write_file(path, head, spec):
    with open(path, "w") as f:
        f.write(head)
        yaml.dump(
            spec, f, Dumper=LiteralDumper, sort_keys=True, default_flow_style=False
        )


def refresh_headers(out, rules):
    """Rewrite the header of every file under out, keeping its contents."""
    n = 0
    for d in sorted(os.listdir(out)):
        for name in sorted(os.listdir(os.path.join(out, d))):
            if not name.endswith(".yaml"):
                continue
            path = os.path.join(out, d, name)
            with open(path) as f:
                lines = f.readlines()
            while lines and lines[0].startswith("#"):
                lines.pop(0)
            body = "".join(lines)
            with open(path, "w") as f:
                f.write(header(d, name[: -len(".yaml")], rules) + body)
            n += 1
    print(f"rewrote {n} headers under {out}", file=sys.stderr)


def main():
    args = sys.argv[1:]
    export_all = "--all" in args
    headers_only = "--headers-only" in args
    args = [a for a in args if a not in ("--all", "--headers-only")]
    rules = None
    if "--rules" in args:
        i = args.index("--rules")
        if i + 1 >= len(args):
            sys.exit(__doc__)
        rules = load_rules(args[i + 1])
        del args[i : i + 2]
    if len(args) != 1 or args[0].startswith("-") or (headers_only and rules is None):
        sys.exit(__doc__)
    out = args[0]
    if headers_only:
        refresh_headers(out, rules)
        return
    items = json.load(sys.stdin)["items"]

    # scan name -> {rule: spec}
    scans = {}
    for r in items:
        name = r["metadata"]["name"]
        if not r["spec"].get("apply") and not export_all:
            continue
        state = r.get("status", {}).get("applicationState", "")
        labels = r["metadata"].get("labels", {})
        skip = [l.split("/")[1] for l in SKIP_LABELS if l in labels]
        if export_all and (state in SKIP_STATES or skip):
            print(
                f"skipped {name}: {state if state in SKIP_STATES else skip[0]}",
                file=sys.stderr,
            )
            continue
        obj = r["spec"]["current"]["object"]
        if obj.get("kind") != "MachineConfig":
            if export_all:
                print(f"skipped {name}: kind {obj.get('kind')}", file=sys.stderr)
                continue
            sys.exit(f"{name}: kind {obj.get('kind')} is not handled")
        scan = r["metadata"]["labels"]["compliance.openshift.io/scan-name"]
        rule = r["metadata"]["name"][len(scan) + 1 :]
        scans.setdefault(scan, {})[rule] = obj["spec"]

    # Pair <profile>-master with <profile>-worker.
    written = 0
    profiles = sorted({re.sub(r"-(master|worker)$", "", s) for s in scans})
    for p in profiles:
        m, w = scans.get(f"{p}-master"), scans.get(f"{p}-worker")
        if m is not None and w is not None:
            if m != w:
                diff = sorted(set(m) ^ set(w)) or sorted(k for k in m if m[k] != w[k])
                sys.exit(f"{p}: master and worker remediations differ: {diff[:10]}")
            sets = {p: w}
        else:
            # Only one role was scanned (ocp4-moderate-node has no worker
            # remediations on 4.22): keep the role in the directory name.
            sets = {f"{p}-master": m} if m is not None else {f"{p}-worker": w}
        for d, rules in sets.items():
            os.makedirs(os.path.join(out, d), exist_ok=True)
            for rule, spec in sorted(rules.items()):
                path = os.path.join(out, d, f"{rule}.yaml")
                write_file(path, header(d, rule, rules), decode_contents(spec))
                written += 1
    print(f"wrote {written} files under {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
