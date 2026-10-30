"""Turn a real `terraform show -json` plan into a shareable test fixture.

Every value Terraform marks as sensitive is swapped for an obviously fake one, so the fixture still
exercises the client's redaction. Subscription, tenant and principal IDs (read from the
azurerm_client_config data source) become placeholder GUIDs, and random_string results become
"abc123". Prints counts only, never the values it replaces.

Usage (from the repo root):
    python -I tests/fixtures/sanitise_fixture.py demo/plan-risky.json tests/fixtures/plan-risky.json
"""
from __future__ import annotations

import json
import re
import sys
from typing import Any, Iterator

PLACEHOLDER_IDS = {
    "subscription_id": "00000000-0000-0000-0000-000000000000",
    "tenant_id": "11111111-1111-1111-1111-111111111111",
    "object_id": "22222222-2222-2222-2222-222222222222",
}
STORAGE_KEY = re.compile(r"^[A-Za-z0-9+/]{86}==$")


def flagged_strings(value: Any, marker: Any) -> Iterator[str]:
    """Strings inside `value` that a Terraform sensitivity marker flags."""
    if marker is True:
        yield from all_strings(value)
    elif isinstance(marker, dict) and isinstance(value, dict):
        for key, sub in marker.items():
            yield from flagged_strings(value.get(key), sub)
    elif isinstance(marker, list) and isinstance(value, list):
        for item, sub in zip(value, marker):
            yield from flagged_strings(item, sub)


def all_strings(value: Any) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from all_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from all_strings(item)


def module_resources(module: dict) -> Iterator[dict]:
    yield from module.get("resources", [])
    for child in module.get("child_modules", []):
        yield from module_resources(child)


def collect_secrets(plan: dict) -> set[str]:
    secrets: set[str] = set()
    for section in ("resource_changes", "resource_drift"):
        for change in (rc.get("change", {}) for rc in plan.get(section, [])):
            for side in ("before", "after"):
                secrets.update(flagged_strings(change.get(side), change.get(f"{side}_sensitive")))
    for change in plan.get("output_changes", {}).values():
        for side in ("before", "after"):
            secrets.update(flagged_strings(change.get(side), change.get(f"{side}_sensitive")))
    for snapshot in (plan.get("prior_state", {}).get("values", {}), plan.get("planned_values", {})):
        for resource in module_resources(snapshot.get("root_module", {})):
            secrets.update(flagged_strings(resource.get("values"), resource.get("sensitive_values")))
        for output in snapshot.get("outputs", {}).values():
            if output.get("sensitive"):
                secrets.update(all_strings(output.get("value")))
    declared = plan.get("configuration", {}).get("root_module", {}).get("variables", {})
    for name, variable in plan.get("variables", {}).items():
        if declared.get(name, {}).get("sensitive"):
            secrets.update(all_strings(variable.get("value")))
    return {s for s in secrets if s}


def collect_ids(plan: dict) -> dict[str, str]:
    replacements: dict[str, str] = {}
    snapshot = plan.get("prior_state", {}).get("values", {}).get("root_module", {})
    for resource in module_resources(snapshot):
        values = resource.get("values") or {}
        if resource.get("type") == "azurerm_client_config":
            for key, placeholder in PLACEHOLDER_IDS.items():
                if values.get(key):
                    replacements[values[key]] = placeholder
        if resource.get("type") == "random_string" and values.get("result"):
            replacements[values["result"]] = "abc123"
    return replacements


def escaped(value: str) -> str:
    """The form a string takes inside JSON text."""
    return json.dumps(value)[1:-1]


def main(source: str, target: str) -> int:
    with open(source, encoding="utf-8") as handle:
        plan = json.load(handle)
    text = json.dumps(plan, indent=2)

    secrets = sorted(collect_secrets(plan), key=len, reverse=True)
    keys = [s for s in secrets if STORAGE_KEY.match(s)]
    for index, secret in enumerate(keys, start=1):
        text = text.replace(secret, f"FAKE-STORAGE-KEY-{index}")
    # Connection strings embed the keys, so most of these are already gone by now.
    others = [s for s in secrets if s not in keys]
    for index, secret in enumerate(others, start=1):
        text = text.replace(escaped(secret), f"FAKE-SENSITIVE-VALUE-{index}")

    ids = collect_ids(plan)
    for real, placeholder in sorted(ids.items(), key=lambda pair: len(pair[0]), reverse=True):
        text = text.replace(real, placeholder)

    leftovers = [s for s in secrets if escaped(s) in text]
    if leftovers or re.search(r"[A-Za-z0-9+/]{86}==", text):
        print(f"refusing to write: {len(leftovers)} sensitive value(s) still present", file=sys.stderr)
        return 1
    with open(target, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text + "\n")
    print(f"{target}: replaced {len(keys)} storage key(s), {len(others)} other sensitive value(s), {len(ids)} ID(s)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
