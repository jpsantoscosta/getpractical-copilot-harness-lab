#!/usr/bin/env python3
"""Deterministic Terraform plan analyser for the tfplan-review skill.

Reads the JSON produced by `terraform show -json <planfile>` and reports risky
Azure changes as findings plus a verdict (BLOCK / REVIEW / PASS).

Standard library only: it runs inside the Microsoft Copilot harness sandbox.

Usage:
    python3 analyze_plan.py PLAN.json [--required-tags environment,owner] [--format json|markdown|summary]

Only addresses, resource types and the specific non-secret attributes a rule
needs (ports, address prefixes, role names, scopes) ever reach the output.
"""
from __future__ import annotations

import argparse
import codecs
import json
import re
import sys
from typing import Any

SCHEMA = "tfplan-review/v1"
SEVERITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}
DEFAULT_REQUIRED_TAGS = ("environment", "owner")
COUNT_KEYS = ("create", "update", "delete", "replace", "no_op", "read", "forget")

# Resources whose destruction loses data or breaks everything inside them.
STATEFUL_TYPES = frozenset({
    "azurerm_storage_account",
    "azurerm_key_vault",
    "azurerm_mssql_database",
    "azurerm_mssql_server",
    "azurerm_postgresql_flexible_server",
    "azurerm_mysql_flexible_server",
    "azurerm_cosmosdb_account",
    "azurerm_managed_disk",
    "azurerm_resource_group",
    "azurerm_recovery_services_vault",
    "azurerm_log_analytics_workspace",
})

PRIVILEGED_ROLE_IDS = {
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635": "Owner",
    "b24988ac-6180-42a0-ab88-20f7382dd24c": "Contributor",
    "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9": "User Access Administrator",
    "f58310d9-a9f6-439a-9e8d-f62e7b41a168": "Role Based Access Control Administrator",
}
PRIVILEGED_ROLE_NAMES = {name.lower(): name for name in PRIVILEGED_ROLE_IDS.values()}

OPEN_SOURCES = frozenset({"*", "internet", "any", "0.0.0.0/0", "0.0.0.0", "::/0"})
MANAGEMENT_PORTS = (22, 3389)

_ACTIONS = {
    (): "no_op",
    ("no-op",): "no_op",
    ("create",): "create",
    ("read",): "read",
    ("update",): "update",
    ("delete",): "delete",
    ("delete", "create"): "replace",
    ("create", "delete"): "replace",
    ("forget",): "forget",
}
CHANGING = ("create", "update", "replace")


def classify_action(actions: list[str] | None) -> str:
    """Map Terraform's action list to one word. Unknown combinations count as an update."""
    return _ACTIONS.get(tuple(actions or ()), "update")


def analyze(plan: dict[str, Any], required_tags: list[str] | None = None) -> dict[str, Any]:
    required = [tag for tag in (DEFAULT_REQUIRED_TAGS if required_tags is None else required_tags) if tag]
    counts = dict.fromkeys(COUNT_KEYS, 0)
    findings: list[dict[str, Any]] = []

    for resource_change in plan.get("resource_changes") or []:
        change = _obj(resource_change.get("change"))
        action = classify_action(change.get("actions"))
        counts[action] += 1
        if resource_change.get("mode", "managed") != "managed":
            continue
        context = _Context(resource_change, change, action, required)
        for rule in RULES:
            findings.extend(rule(context))

    findings.sort(key=lambda f: (SEVERITY_RANK[f["severity"]], f["address"], f["rule_id"]))
    redaction = plan.get("x_redaction")
    return {
        "schema": SCHEMA,
        "terraform_version": plan.get("terraform_version"),
        "counts": counts,
        "verdict": _verdict(findings),
        "findings": findings,
        "redaction": {"redacted_values": int(redaction.get("redacted_values", 0))} if isinstance(redaction, dict) else None,
    }


class _Context:
    def __init__(self, resource_change: dict[str, Any], change: dict[str, Any], action: str, required: list[str]):
        self.resource_change = resource_change
        self.type = resource_change.get("type") or ""
        self.address = resource_change.get("address") or "(unknown address)"
        self.actions = list(change.get("actions") or [])
        self.action = action
        self.before = _obj(change.get("before"))
        self.after = _obj(change.get("after"))
        self.after_unknown = change.get("after_unknown")
        self.replace_paths = change.get("replace_paths") or []
        self.required = required

    @property
    def stateful(self) -> bool:
        return self.type in STATEFUL_TYPES

    def unknown(self, key: str) -> bool:
        if self.after_unknown is True:
            return True
        return isinstance(self.after_unknown, dict) and self.after_unknown.get(key) is True

    def finding(self, rule_id: str, severity: str, title: str, detail: str) -> dict[str, Any]:
        return {
            "rule_id": rule_id,
            "severity": severity,
            "address": self.address,
            "type": self.type,
            "action": self.action,
            "title": title,
            "detail": detail,
        }


def _rule_delete(c: _Context) -> list[dict[str, Any]]:
    if c.action != "delete":
        return []
    detail = f"{c.type} will be destroyed"
    if c.stateful:
        detail += "; it holds data or other resources"
    reason = c.resource_change.get("action_reason")
    if reason:
        detail += f" (reason: {reason})"
    return [c.finding("TFR001", "critical" if c.stateful else "high", "Resource will be destroyed", detail)]


def _rule_replace(c: _Context) -> list[dict[str, Any]]:
    if c.action != "replace":
        return []
    order = "create before destroy" if c.actions[:1] == ["create"] else "destroy before create"
    detail = f"{c.type} will be replaced ({order})"
    forced_by = sorted({".".join(str(step) for step in path) for path in c.replace_paths if path})
    if forced_by:
        detail += f"; forced by: {', '.join(forced_by)}"
    if c.stateful:
        detail += "; data in the old resource is lost unless migrated"
    return [c.finding("TFR002", "critical" if c.stateful else "high", "Resource will be replaced", detail)]


def _is_public(values: dict[str, Any]) -> bool:
    return values.get("public_network_access_enabled") is True or str(values.get("public_network_access") or "").lower() == "enabled"


def _rule_public_network_access(c: _Context) -> list[dict[str, Any]]:
    if c.action not in CHANGING or not _is_public(c.after) or _is_public(c.before):
        return []
    return [c.finding("TFR003", "high", "Public network access enabled",
                      f"{c.type} will accept traffic from public networks")]


def _port_spec_covers(spec: Any, port: int) -> bool:
    text = str(spec).strip()
    if text == "*":
        return True
    low, sep, high = text.partition("-")
    try:
        if sep:
            return int(low) <= port <= int(high)
        return int(text) == port
    except ValueError:
        return False


def _exposed_management_ports(rule: dict[str, Any]) -> list[int]:
    if str(rule.get("direction") or "").lower() != "inbound" or str(rule.get("access") or "").lower() != "allow":
        return []
    if str(rule.get("protocol") or "*").lower() == "icmp":
        return []
    sources = [rule.get("source_address_prefix")] + list(rule.get("source_address_prefixes") or [])
    if not any(str(source).strip().lower() in OPEN_SOURCES for source in sources if source):
        return []
    port_specs = [rule.get("destination_port_range")] + list(rule.get("destination_port_ranges") or [])
    return [port for port in MANAGEMENT_PORTS if any(_port_spec_covers(spec, port) for spec in port_specs if spec)]


def _open_management_rules(resource_type: str, values: dict[str, Any]) -> dict[str, list[int]]:
    if resource_type == "azurerm_network_security_rule":
        rules = [values] if values else []
    elif resource_type == "azurerm_network_security_group":
        rules = [rule for rule in values.get("security_rule") or [] if isinstance(rule, dict)]
    else:
        return {}
    exposed = {}
    for rule in rules:
        ports = _exposed_management_ports(rule)
        if ports:
            exposed[str(rule.get("name") or "(unnamed)")] = ports
    return exposed


def _rule_management_ports(c: _Context) -> list[dict[str, Any]]:
    if c.action not in CHANGING:
        return []
    before = _open_management_rules(c.type, c.before)
    after = _open_management_rules(c.type, c.after)
    return [
        c.finding("TFR004", "critical", "Management port open to the internet",
                  f"inbound Allow from the internet to port(s) {', '.join(str(p) for p in ports)} (rule {name})")
        for name, ports in sorted(after.items())
        if before.get(name) != ports
    ]


def _privileged_role(values: dict[str, Any]) -> str | None:
    name = str(values.get("role_definition_name") or "").strip().lower()
    if name in PRIVILEGED_ROLE_NAMES:
        return PRIVILEGED_ROLE_NAMES[name]
    role_id = str(values.get("role_definition_id") or "").rstrip("/")
    return PRIVILEGED_ROLE_IDS.get(role_id.rsplit("/", 1)[-1].lower())


def _scope_kind(scope: str) -> str:
    lowered = scope.lower().rstrip("/")
    if not lowered:
        return "unknown (known after apply)"
    if "/providers/microsoft.management/managementgroups/" in lowered:
        return "management group"
    if re.fullmatch(r"/subscriptions/[^/]+", lowered):
        return "subscription"
    if re.fullmatch(r"/subscriptions/[^/]+/resourcegroups/[^/]+", lowered):
        return "resource group"
    return "resource"


def _rule_privileged_role(c: _Context) -> list[dict[str, Any]]:
    if c.type != "azurerm_role_assignment" or c.action not in ("create", "replace"):
        return []
    role = _privileged_role(c.after)
    if not role:
        return []
    scope = str(c.after.get("scope") or "")
    kind = _scope_kind(scope)
    severity = "critical" if kind in ("subscription", "management group") else "high"
    detail = f"grants {role} at {kind} scope" + (f" ({scope})" if scope else "")
    return [c.finding("TFR005", severity, "Privileged role assignment", detail)]


def _rule_lock_removed(c: _Context) -> list[dict[str, Any]]:
    if c.type != "azurerm_management_lock" or c.action not in ("delete", "replace"):
        return []
    level = c.before.get("lock_level") or "management"
    verb = "removed and recreated" if c.action == "replace" else "removed"
    return [c.finding("TFR006", "high", "Resource lock removed",
                      f"{level} lock '{c.before.get('name') or c.address}' will be {verb}")]


def _tag_keys(values: dict[str, Any]) -> set[str]:
    return {str(key).lower() for key in _obj(values.get("tags"))}


def _rule_missing_tags(c: _Context) -> list[dict[str, Any]]:
    if c.action not in CHANGING or "tags" not in c.after or c.unknown("tags") or not c.required:
        return []
    after_keys = _tag_keys(c.after)
    missing = [tag for tag in c.required if tag.lower() not in after_keys]
    if c.action == "update":
        # Only report tags this change removes; pre-existing gaps are not this plan's doing.
        before_keys = _tag_keys(c.before)
        missing = [tag for tag in missing if tag.lower() in before_keys]
    if not missing:
        return []
    return [c.finding("TFR007", "low", "Required tags missing", f"missing required tag(s): {', '.join(missing)}")]


def _rule_public_blobs(c: _Context) -> list[dict[str, Any]]:
    if c.type != "azurerm_storage_account" or c.action not in CHANGING:
        return []
    if c.after.get("allow_nested_items_to_be_public") is not True or c.before.get("allow_nested_items_to_be_public") is True:
        return []
    return [c.finding("TFR008", "high", "Anonymous blob access allowed",
                      "containers in this storage account can be made publicly readable")]


RULES = (
    _rule_delete,
    _rule_replace,
    _rule_public_network_access,
    _rule_management_ports,
    _rule_privileged_role,
    _rule_lock_removed,
    _rule_missing_tags,
    _rule_public_blobs,
)


def _verdict(findings: list[dict[str, Any]]) -> str:
    severities = {finding["severity"] for finding in findings}
    if "critical" in severities:
        return "BLOCK"
    if severities & {"high", "medium"}:
        return "REVIEW"
    return "PASS"


def _obj(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def render_markdown(result: dict[str, Any]) -> str:
    counts = result["counts"]
    lines = [
        "## Terraform plan review",
        "",
        f"Verdict: **{result['verdict']}**",
        "",
        "| create | update | replace | delete | no-op |",
        "| --- | --- | --- | --- | --- |",
        f"| {counts['create']} | {counts['update']} | {counts['replace']} | {counts['delete']} | {counts['no_op']} |",
        "",
    ]
    if result["findings"]:
        lines += ["| Severity | Rule | Resource | Finding |", "| --- | --- | --- | --- |"]
        for f in result["findings"]:
            text = f"{f['title']}: {f['detail']}".replace("|", "\\|")
            lines.append(f"| {f['severity']} | {f['rule_id']} | `{f['address']}` | {text} |")
    else:
        lines.append("No risky changes found.")
    if result.get("redaction"):
        lines += ["", f"{result['redaction']['redacted_values']} sensitive value(s) were redacted before upload."]
    return "\n".join(lines) + "\n"


def render_summary(result: dict[str, Any]) -> str:
    """The machine-readable block the agent pastes verbatim at the end of its reply."""
    summary = {
        "verdict": result["verdict"],
        "counts": result["counts"],
        "findings": [{key: f[key] for key in ("rule_id", "severity", "address")} for f in result["findings"]],
    }
    return "```tfplan-review-summary\n" + json.dumps(summary) + "\n```\n"


RENDERERS = {
    "json": lambda result: json.dumps(result, indent=2) + "\n",
    "markdown": render_markdown,
    "summary": render_summary,
}


def _read_json(path: str) -> Any:
    with open(path, "rb") as handle:
        raw = handle.read()
    # Windows PowerShell 5.1 redirects (`>`) as UTF-16; pwsh and terraform write UTF-8.
    if raw.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        text = raw.decode("utf-16")
    else:
        text = raw.decode("utf-8-sig")
    return json.loads(text)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Report risky Azure changes in a Terraform JSON plan.")
    parser.add_argument("plan", help="path to the output of `terraform show -json <planfile>`")
    parser.add_argument("--required-tags", default=",".join(DEFAULT_REQUIRED_TAGS),
                        help="comma-separated tag keys every created resource must carry (default: %(default)s)")
    parser.add_argument("--format", choices=tuple(RENDERERS), default="json",
                        help="json (full result), markdown (report table) or summary (fenced block for the reply)")
    args = parser.parse_args(argv)

    try:
        data = _read_json(args.plan)
    except OSError as error:
        print(f"analyze_plan: cannot read {args.plan}: {error.strerror or error}", file=sys.stderr)
        return 2
    except (ValueError, UnicodeDecodeError) as error:
        print(f"analyze_plan: {args.plan} is not valid JSON: {error}", file=sys.stderr)
        return 2
    if not isinstance(data, dict):
        print(f"analyze_plan: {args.plan} is not a Terraform JSON plan", file=sys.stderr)
        return 2

    required = [tag.strip() for tag in args.required_tags.split(",") if tag.strip()]
    sys.stdout.write(RENDERERS[args.format](analyze(data, required)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
