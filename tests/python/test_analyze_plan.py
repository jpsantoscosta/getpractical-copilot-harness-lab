"""Unit tests for the tfplan-review skill's deterministic analyser.

Run from the repo root:  python -m unittest discover -s tests/python -v
"""
from __future__ import annotations

import importlib.util
import io
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "agent" / "skills" / "tfplan-review" / "scripts" / "analyze_plan.py"

sys.dont_write_bytecode = True  # keep the packaged skill folder free of __pycache__
_spec = importlib.util.spec_from_file_location("analyze_plan", SCRIPT)
analyze_plan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(analyze_plan)


class PackagingTests(unittest.TestCase):
    def test_import_leaves_skill_folder_clean(self):
        # azd zips agent/skills/tfplan-review as-is, so test runs must not drop bytecode into it.
        self.assertFalse((SCRIPT.parent / "__pycache__").exists())


def plan(*changes, **extra):
    body = {"format_version": "1.2", "terraform_version": "1.14.9", "resource_changes": list(changes)}
    body.update(extra)
    return body


def rc(address, type_, actions, before=None, after=None, **change_extra):
    change = {"actions": actions, "before": before, "after": after, "after_unknown": {}}
    change.update(change_extra)
    return {"address": address, "mode": "managed", "type": type_, "name": address.split(".")[-1], "change": change}


def rule_hits(result, rule_id):
    return [f for f in result["findings"] if f["rule_id"] == rule_id]


TAGS = {"environment": "lab", "owner": "joao"}


class ClassifyActionTests(unittest.TestCase):
    def test_classify_actions(self):
        cases = {
            ("no-op",): "no_op",
            ("create",): "create",
            ("read",): "read",
            ("update",): "update",
            ("delete",): "delete",
            ("delete", "create"): "replace",
            ("create", "delete"): "replace",
            ("forget",): "forget",
        }
        for actions, expected in cases.items():
            with self.subTest(actions=actions):
                self.assertEqual(analyze_plan.classify_action(list(actions)), expected)


class AnalyzeTests(unittest.TestCase):
    def test_empty_plan_passes(self):
        result = analyze_plan.analyze(plan(rc("azurerm_resource_group.rg", "azurerm_resource_group", ["no-op"], TAGS, TAGS)))
        self.assertEqual(result["schema"], "tfplan-review/v1")
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["findings"], [])
        self.assertEqual(result["counts"]["no_op"], 1)
        self.assertEqual(analyze_plan.analyze({"format_version": "1.2"})["verdict"], "PASS")

    def test_counts_every_action_kind(self):
        result = analyze_plan.analyze(plan(
            rc("a.one", "azurerm_user_assigned_identity", ["create"], None, {"tags": TAGS}),
            rc("a.two", "azurerm_user_assigned_identity", ["update"], {"tags": TAGS}, {"tags": TAGS}),
            rc("a.three", "azurerm_user_assigned_identity", ["delete"], {"tags": TAGS}, None),
            rc("a.four", "azurerm_user_assigned_identity", ["delete", "create"], {"tags": TAGS}, {"tags": TAGS}),
            rc("a.five", "azurerm_user_assigned_identity", ["no-op"], {"tags": TAGS}, {"tags": TAGS}),
        ))
        self.assertEqual(result["counts"], {"create": 1, "update": 1, "delete": 1, "replace": 1, "no_op": 1, "read": 0, "forget": 0})

    def test_data_sources_are_ignored(self):
        data = rc("data.azurerm_client_config.current", "azurerm_client_config", ["read"])
        data["mode"] = "data"
        result = analyze_plan.analyze(plan(data))
        self.assertEqual(result["counts"]["read"], 1)
        self.assertEqual(result["findings"], [])

    def test_unknown_values_do_not_crash(self):
        change = rc("azurerm_storage_account.sa", "azurerm_storage_account", ["create"], None,
                    {"name": "stdemo", "public_network_access_enabled": None, "tags": None},
                    after_unknown={"id": True, "tags": True, "public_network_access_enabled": True})
        rule = rc("azurerm_network_security_rule.r", "azurerm_network_security_rule", ["create"], None, None,
                  after_unknown=True)
        result = analyze_plan.analyze(plan(change, rule))
        self.assertEqual(result["verdict"], "PASS")

    def test_tfr001_delete_is_high_and_critical_when_stateful(self):
        result = analyze_plan.analyze(plan(
            rc("azurerm_user_assigned_identity.id", "azurerm_user_assigned_identity", ["delete"], {"tags": TAGS}, None),
            rc("azurerm_key_vault.kv", "azurerm_key_vault", ["delete"], {"tags": TAGS}, None,
               ) | {"action_reason": "delete_because_no_resource_config"},
        ))
        hits = {f["address"]: f["severity"] for f in rule_hits(result, "TFR001")}
        self.assertEqual(hits, {"azurerm_user_assigned_identity.id": "high", "azurerm_key_vault.kv": "critical"})
        kv = next(f for f in result["findings"] if f["address"] == "azurerm_key_vault.kv")
        self.assertIn("delete_because_no_resource_config", kv["detail"])

    def test_tfr001_not_raised_for_replace(self):
        result = analyze_plan.analyze(plan(
            rc("azurerm_user_assigned_identity.id", "azurerm_user_assigned_identity", ["delete", "create"], {"tags": TAGS}, {"tags": TAGS})))
        self.assertEqual(rule_hits(result, "TFR001"), [])

    def test_tfr002_replace_lists_forcing_attributes(self):
        result = analyze_plan.analyze(plan(rc(
            "azurerm_storage_account.sa", "azurerm_storage_account", ["delete", "create"],
            {"name": "stold", "tags": TAGS}, {"name": "stnew", "tags": TAGS}, replace_paths=[["name"]])))
        [hit] = rule_hits(result, "TFR002")
        self.assertEqual(hit["severity"], "critical")
        self.assertIn("name", hit["detail"])
        self.assertEqual(hit["action"], "replace")

    def test_tfr002_replace_of_stateless_resource_is_high(self):
        result = analyze_plan.analyze(plan(rc(
            "azurerm_user_assigned_identity.id", "azurerm_user_assigned_identity", ["create", "delete"],
            {"name": "id-old", "tags": TAGS}, {"name": "id-new", "tags": TAGS}, replace_paths=[["name"]])))
        self.assertEqual([f["severity"] for f in rule_hits(result, "TFR002")], ["high"])

    def test_tfr003_public_network_access_turned_on(self):
        result = analyze_plan.analyze(plan(
            rc("azurerm_key_vault.on", "azurerm_key_vault", ["update"],
               {"public_network_access_enabled": False, "tags": TAGS}, {"public_network_access_enabled": True, "tags": TAGS}),
            rc("azurerm_key_vault.already", "azurerm_key_vault", ["update"],
               {"public_network_access_enabled": True, "tags": TAGS}, {"public_network_access_enabled": True, "tags": TAGS}),
            rc("azurerm_container_registry.acr", "azurerm_container_registry", ["create"], None,
               {"public_network_access": "Enabled", "tags": TAGS}),
        ))
        self.assertEqual(sorted(f["address"] for f in rule_hits(result, "TFR003")),
                         ["azurerm_container_registry.acr", "azurerm_key_vault.on"])
        self.assertTrue(all(f["severity"] == "high" for f in rule_hits(result, "TFR003")))

    def test_tfr004_rdp_from_internet_is_critical(self):
        rule = {"direction": "Inbound", "access": "Allow", "protocol": "Tcp",
                "source_address_prefix": "Internet", "destination_port_range": "3389", "name": "allow-rdp"}
        result = analyze_plan.analyze(plan(rc(
            "azurerm_network_security_rule.rdp", "azurerm_network_security_rule", ["create"], None, rule)))
        [hit] = rule_hits(result, "TFR004")
        self.assertEqual(hit["severity"], "critical")
        self.assertIn("3389", hit["detail"])

    def test_tfr004_inline_rules_ranges_and_lists(self):
        open_ssh = {"name": "ssh", "direction": "Inbound", "access": "Allow", "protocol": "*",
                    "source_address_prefix": "", "source_address_prefixes": ["10.0.0.0/8", "0.0.0.0/0"],
                    "destination_port_range": "", "destination_port_ranges": ["20-23", "443"]}
        private_rdp = {"name": "rdp-private", "direction": "Inbound", "access": "Allow", "protocol": "Tcp",
                       "source_address_prefix": "10.0.0.0/8", "destination_port_range": "3389"}
        deny_all = {"name": "deny", "direction": "Inbound", "access": "Deny", "protocol": "*",
                    "source_address_prefix": "*", "destination_port_range": "*"}
        result = analyze_plan.analyze(plan(rc(
            "azurerm_network_security_group.nsg", "azurerm_network_security_group", ["update"],
            {"security_rule": [private_rdp, deny_all], "tags": TAGS},
            {"security_rule": [private_rdp, deny_all, open_ssh], "tags": TAGS})))
        [hit] = rule_hits(result, "TFR004")
        self.assertIn("ssh", hit["detail"])
        self.assertIn("22", hit["detail"])

    def test_tfr004_https_from_internet_is_fine(self):
        rule = {"direction": "Inbound", "access": "Allow", "protocol": "Tcp",
                "source_address_prefix": "*", "destination_port_range": "443", "name": "https"}
        result = analyze_plan.analyze(plan(rc(
            "azurerm_network_security_rule.https", "azurerm_network_security_rule", ["create"], None, rule)))
        self.assertEqual(rule_hits(result, "TFR004"), [])

    def test_tfr005_privileged_role_assignment(self):
        rg_scope = "/subscriptions/0000/resourceGroups/rg-demo"
        result = analyze_plan.analyze(plan(
            rc("azurerm_role_assignment.owner_rg", "azurerm_role_assignment", ["create"], None,
               {"role_definition_name": "Owner", "scope": rg_scope, "principal_id": "p1"}),
            rc("azurerm_role_assignment.contrib_sub", "azurerm_role_assignment", ["create"], None,
               {"role_definition_name": None, "scope": "/subscriptions/0000",
                "role_definition_id": "/subscriptions/0000/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"}),
            rc("azurerm_role_assignment.reader", "azurerm_role_assignment", ["create"], None,
               {"role_definition_name": "Reader", "scope": "/subscriptions/0000", "principal_id": "p3"}),
        ))
        hits = {f["address"]: f["severity"] for f in rule_hits(result, "TFR005")}
        self.assertEqual(hits, {"azurerm_role_assignment.owner_rg": "high", "azurerm_role_assignment.contrib_sub": "critical"})

    def test_tfr006_lock_removed(self):
        result = analyze_plan.analyze(plan(
            rc("azurerm_management_lock.storage", "azurerm_management_lock", ["delete"],
               {"name": "lock-storage", "lock_level": "CanNotDelete"}, None),
            rc("azurerm_management_lock.new", "azurerm_management_lock", ["create"], None,
               {"name": "lock-new", "lock_level": "CanNotDelete"}),
        ))
        self.assertEqual([f["address"] for f in rule_hits(result, "TFR006")], ["azurerm_management_lock.storage"])
        self.assertEqual(rule_hits(result, "TFR006")[0]["severity"], "high")

    def test_tfr007_missing_required_tags(self):
        result = analyze_plan.analyze(plan(
            rc("azurerm_resource_group.new", "azurerm_resource_group", ["create"], None, {"tags": {"Environment": "lab"}}),
            rc("azurerm_resource_group.dropped", "azurerm_resource_group", ["update"], {"tags": TAGS}, {"tags": {"environment": "lab"}}),
            rc("azurerm_resource_group.legacy", "azurerm_resource_group", ["update"], {"tags": {}}, {"tags": {"cost": "x"}}),
            rc("azurerm_resource_group.ok", "azurerm_resource_group", ["create"], None, {"tags": {"ENVIRONMENT": "lab", "Owner": "j"}}),
        ))
        hits = {f["address"]: f["detail"] for f in rule_hits(result, "TFR007")}
        self.assertEqual(sorted(hits), ["azurerm_resource_group.dropped", "azurerm_resource_group.new"])
        self.assertIn("owner", hits["azurerm_resource_group.new"])
        self.assertTrue(all(f["severity"] == "low" for f in rule_hits(result, "TFR007")))

    def test_tfr007_honours_custom_required_tags(self):
        result = analyze_plan.analyze(
            plan(rc("azurerm_resource_group.new", "azurerm_resource_group", ["create"], None, {"tags": TAGS})),
            required_tags=["cost-centre"])
        [hit] = rule_hits(result, "TFR007")
        self.assertIn("cost-centre", hit["detail"])

    def test_tfr008_public_blob_access(self):
        result = analyze_plan.analyze(plan(
            rc("azurerm_storage_account.sa", "azurerm_storage_account", ["update"],
               {"allow_nested_items_to_be_public": False, "tags": TAGS}, {"allow_nested_items_to_be_public": True, "tags": TAGS}),
            rc("azurerm_storage_account.private", "azurerm_storage_account", ["create"], None,
               {"allow_nested_items_to_be_public": False, "tags": TAGS}),
        ))
        self.assertEqual([(f["address"], f["severity"]) for f in rule_hits(result, "TFR008")],
                         [("azurerm_storage_account.sa", "high")])

    def test_verdict_precedence(self):
        low_only = plan(rc("azurerm_resource_group.a", "azurerm_resource_group", ["create"], None, {"tags": {}}))
        high = plan(rc("azurerm_management_lock.l", "azurerm_management_lock", ["delete"], {"name": "l"}, None))
        critical = plan(rc("azurerm_key_vault.kv", "azurerm_key_vault", ["delete"], {"tags": TAGS}, None))
        self.assertEqual(analyze_plan.analyze(low_only)["verdict"], "PASS")
        self.assertEqual(analyze_plan.analyze(high)["verdict"], "REVIEW")
        self.assertEqual(analyze_plan.analyze(critical)["verdict"], "BLOCK")

    def test_findings_sorted_by_severity_then_address(self):
        result = analyze_plan.analyze(plan(
            rc("azurerm_resource_group.z", "azurerm_resource_group", ["create"], None, {"tags": {}}),
            rc("azurerm_management_lock.b", "azurerm_management_lock", ["delete"], {"name": "b"}, None),
            rc("azurerm_key_vault.a", "azurerm_key_vault", ["delete"], {"tags": TAGS}, None),
            rc("azurerm_management_lock.a", "azurerm_management_lock", ["delete"], {"name": "a"}, None),
        ))
        order = [(f["severity"], f["address"], f["rule_id"]) for f in result["findings"]]
        self.assertEqual(order, sorted(order, key=lambda o: ({"critical": 0, "high": 1, "medium": 2, "low": 3}[o[0]], o[1], o[2])))
        self.assertEqual(order[0][0], "critical")

    def test_redaction_metadata_is_reported(self):
        result = analyze_plan.analyze(plan(x_redaction={"redacted_values": 7, "dropped_sections": ["prior_state"]}))
        self.assertEqual(result["redaction"], {"redacted_values": 7})
        self.assertIsNone(analyze_plan.analyze(plan())["redaction"])


class RealPlanFixtureTests(unittest.TestCase):
    """Plans produced by real `terraform show -json` runs of demo/, sanitised by tests/fixtures/sanitise_fixture.py."""

    def load(self, name):
        with open(REPO / "tests" / "fixtures" / name, encoding="utf-8") as handle:
            return json.load(handle)

    def test_baseline_fixture_passes(self):
        result = analyze_plan.analyze(self.load("plan-baseline.json"))
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["findings"], [])
        self.assertGreaterEqual(result["counts"]["create"], 5)

    def test_risky_fixture_expected_findings(self):
        result = analyze_plan.analyze(self.load("plan-risky.json"))
        found = sorted((f["rule_id"], f["severity"], f["address"]) for f in result["findings"])
        self.assertEqual(found, sorted([
            ("TFR001", "high", "azurerm_management_lock.storage[0]"),
            ("TFR002", "critical", "azurerm_storage_account.demo"),
            ("TFR003", "high", "azurerm_storage_account.demo"),
            ("TFR004", "critical", "azurerm_network_security_rule.allow_rdp[0]"),
            ("TFR005", "high", "azurerm_role_assignment.owner[0]"),
            ("TFR006", "high", "azurerm_management_lock.storage[0]"),
            ("TFR007", "low", "azurerm_storage_account.demo"),
            ("TFR008", "high", "azurerm_storage_account.demo"),
        ]))
        self.assertEqual(result["verdict"], "BLOCK")
        self.assertEqual({k: result["counts"][k] for k in ("create", "delete", "replace")},
                         {"create": 2, "delete": 1, "replace": 1})
        replace = next(f for f in result["findings"] if f["rule_id"] == "TFR002")
        self.assertIn("forced by: name", replace["detail"])

    def test_risky_fixture_still_carries_fake_secrets_for_redaction_tests(self):
        text = (REPO / "tests" / "fixtures" / "plan-risky.json").read_text(encoding="utf-8")
        self.assertIn("FAKE-STORAGE-KEY", text)

    def test_fixtures_hold_no_real_azure_ids(self):
        placeholders = {"00000000-0000-0000-0000-000000000000", "11111111-1111-1111-1111-111111111111",
                        "22222222-2222-2222-2222-222222222222"}
        public = {"04b07795-8ddb-461a-bbee-02f9e1bf7b46"}  # Azure CLI's published client ID
        for name in ("plan-baseline.json", "plan-risky.json"):
            with self.subTest(fixture=name):
                plan = self.load(name)
                # terraform_data IDs are random UUIDs Terraform makes up locally, not Azure IDs.
                local = {(rc["change"].get(side) or {}).get("id") for rc in plan["resource_changes"]
                         if rc["type"] == "terraform_data" for side in ("before", "after")}
                found = {g.lower() for g in re.findall(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", json.dumps(plan), re.I)}
                self.assertEqual(found - placeholders - public - local, set(), "sanitise real subscription, tenant or principal IDs")


class OutputTests(unittest.TestCase):
    RISKY = plan(
        rc("azurerm_storage_account.sa", "azurerm_storage_account", ["update"],
           {"primary_access_key": "SUPER-SECRET-KEY==", "allow_nested_items_to_be_public": False, "tags": TAGS},
           {"primary_access_key": "SUPER-SECRET-KEY==", "allow_nested_items_to_be_public": True,
            "primary_connection_string": "DefaultEndpointsProtocol=https;AccountKey=SUPER-SECRET-KEY==", "tags": TAGS}),
    )

    def _write(self, data):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        with handle:
            json.dump(data, handle)
        self.addCleanup(pathlib.Path(handle.name).unlink)
        return handle.name

    def _run(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=False)

    def test_cli_json_output(self):
        proc = self._run(self._write(self.RISKY))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["verdict"], "REVIEW")
        self.assertEqual([f["rule_id"] for f in result["findings"]], ["TFR008"])

    def test_cli_required_tags_option(self):
        proc = self._run(self._write(plan(rc("azurerm_resource_group.rg", "azurerm_resource_group", ["create"], None, {"tags": TAGS}))),
                         "--required-tags", "cost-centre,owner")
        result = json.loads(proc.stdout)
        self.assertEqual([f["rule_id"] for f in result["findings"]], ["TFR007"])

    def test_cli_rejects_unreadable_input(self):
        missing = self._run(str(REPO / "does-not-exist.json"))
        self.assertEqual(missing.returncode, 2)
        bad = self._run(self._write_text("{not json"))
        self.assertEqual(bad.returncode, 2)
        self.assertIn("not valid JSON", bad.stderr)

    def _write_text(self, text):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        with handle:
            handle.write(text)
        self.addCleanup(pathlib.Path(handle.name).unlink)
        return handle.name

    def test_markdown_output_lists_findings(self):
        proc = self._run(self._write(self.RISKY), "--format", "markdown")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Verdict: **REVIEW**", proc.stdout)
        self.assertIn("| high | TFR008 | `azurerm_storage_account.sa` |", proc.stdout)

    def test_cli_summary_output_is_the_exact_fenced_block(self):
        proc = self._run(self._write(self.RISKY), "--format", "summary")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.strip().splitlines()
        self.assertEqual(lines[0], "```tfplan-review-summary")
        self.assertEqual(lines[-1], "```")
        self.assertEqual(len(lines), 3)
        summary = json.loads(lines[1])
        self.assertEqual(summary, {
            "verdict": "REVIEW",
            "counts": {"create": 0, "update": 1, "delete": 0, "replace": 0, "no_op": 0, "read": 0, "forget": 0},
            "findings": [{"rule_id": "TFR008", "severity": "high", "address": "azurerm_storage_account.sa"}],
        })

    def test_never_echoes_sensitive_values(self):
        for fmt in ("json", "markdown", "summary"):
            with self.subTest(fmt=fmt):
                buffer = io.StringIO()
                with redirect_stdout(buffer):
                    code = analyze_plan.main([self._write(self.RISKY), "--format", fmt])
                self.assertEqual(code, 0)
                self.assertNotIn("SUPER-SECRET-KEY", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
