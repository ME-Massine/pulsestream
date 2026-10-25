"""Regression checks for the compatibility policy, independent of service models."""

from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("contracts", Path(__file__).with_name("check-event-contracts.py"))
contracts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(contracts)


BOOLEAN_NUMBER_PAIRS = (
    (True, 1),
    (False, 0),
    (True, 1.0),
    (False, 0.0),
    ({"enabled": True}, {"enabled": 1}),
    ([False], [0]),
    ({"flags": [True, {"enabled": False}]}, {"flags": [1, {"enabled": 0}]}),
)


class CompatibilityTest(unittest.TestCase):
    def setUp(self):
        self.old = json.loads((Path(__file__).resolve().parents[2] /
                               "contracts/schemas/raw/v1.schema.json").read_text(encoding="utf-8"))
        self.new = deepcopy(self.old)

    def test_optional_addition_and_annotations(self):
        self.new["description"] = "Clarified semantics"
        self.new["properties"]["traceContext"] = {"type": "object", "additionalProperties": True}
        self.new["properties"]["payload"]["properties"]["calibration"] = {"type": "string"}
        self.assertEqual([], contracts.compare(self.old, self.new))

    def test_rejects_breaking_changes_without_relying_on_fixtures(self):
        mutations = [
            lambda s: s["required"].append("future"),
            lambda s: s["required"].remove("source"),
            lambda s: s["properties"].pop("source"),
            lambda s: s["properties"]["payload"]["properties"]["value"].update(type="string"),
            lambda s: s["properties"]["timestamp"].update(format="date"),
            lambda s: s["properties"]["eventType"].update(const="renamed"),
            lambda s: s.update(additionalProperties=False),
            lambda s: s.update(unevaluatedProperties=False),
            lambda s: s["properties"]["payload"].update(additionalProperties=False),
            lambda s: s["properties"]["payload"]["properties"]["value"].update(minimum=0),
            lambda s: s["properties"]["version"].update(pattern=r"^2\.[0-9]+$"),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                candidate = deepcopy(self.old)
                mutate(candidate)
                self.assertTrue(contracts.compare(self.old, candidate))

    def test_enum_items_refs_and_unknown_keywords_fail_closed(self):
        for old, new in [
            ({"enum": ["WARNING", "CRITICAL"]}, {"enum": ["WARNING"]}),
            ({"items": {"type": "string"}}, {"items": {"type": "number"}}),
            ({"$ref": "#/$defs/payload"}, {"$ref": "#/$defs/other"}),
            ({"newValidator": 1}, {"newValidator": 2}),
            ({"$defs": {"payload": {"type": "number"}}}, {"$defs": {}}),
            ({"const": {"description": "a"}}, {"const": {"description": "b"}}),
        ]:
            self.assertTrue(contracts.compare(old, new))

    def test_boolean_number_constraints_are_distinct(self):
        for boolean, number in BOOLEAN_NUMBER_PAIRS:
            for before, after in ((boolean, number), (number, boolean)):
                for keyword in ("const", "enum"):
                    with self.subTest(before=before, after=after, keyword=keyword):
                        old = {keyword: [before] if keyword == "enum" else before}
                        new = {keyword: [after] if keyword == "enum" else after}
                        self.assertEqual([f"$/{keyword}: validation rule changed"],
                                         contracts.compare(old, new))
        for before, after in ((True, 1), (1, True), (False, 0), (0, False)):
            with self.subTest(before=before, after=after):
                self.assertTrue(contracts.compare(before, after))

    def test_equivalent_json_values_remain_compatible(self):
        for before, after in (
            (True, True),
            (False, False),
            (1, 1.0),
            (0.0, 0),
            ({"enabled": True, "values": [None, 1, False, "text"]},
             {"values": [None, 1.0, False, "text"], "enabled": True}),
        ):
            for keyword in ("const", "enum"):
                with self.subTest(before=before, after=after, keyword=keyword):
                    old = {keyword: [before] if keyword == "enum" else before}
                    new = {keyword: [after] if keyword == "enum" else after}
                    self.assertEqual([], contracts.compare(old, new))

    def test_git_baseline_rejects_boolean_number_constraints(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(Path(__file__).resolve().parents[2] / "contracts", root / "contracts")
            schema_file = root / "contracts/schemas/raw/v1.schema.json"
            baseline = json.loads(schema_file.read_text(encoding="utf-8"))
            changes = []
            for boolean, number in BOOLEAN_NUMBER_PAIRS:
                for before, after in ((boolean, number), (number, boolean)):
                    for keyword in ("const", "enum"):
                        name = f"optionalConstraint{len(changes)}"
                        baseline["properties"][name] = {
                            keyword: [before] if keyword == "enum" else before}
                        changes.append((name, keyword, [after] if keyword == "enum" else after))
            schema_file.write_text(json.dumps(baseline), encoding="utf-8")
            contracts.git(root, "init", "--quiet")
            contracts.git(root, "add", ".")
            contracts.git(root, "-c", "user.name=Contract Test", "-c", "user.email=contracts@example.invalid",
                          "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Published contracts")
            self.assertEqual([], contracts.check(root, "HEAD"))
            for name, keyword, value in changes:
                with self.subTest(property=name, keyword=keyword, value=value):
                    candidate = deepcopy(baseline)
                    candidate["properties"][name][keyword] = value
                    schema_file.write_text(json.dumps(candidate), encoding="utf-8")
                    self.assertEqual([
                        f"contracts/schemas/raw/v1.schema.json: $/properties/{name}/{keyword}: validation rule changed"
                    ], contracts.check(root, "HEAD"))

    def test_git_baseline_new_major_and_retention(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True)
            git("init", "--quiet")
            for topic in contracts.TOPICS:
                file = root / f"contracts/schemas/{topic}/v1.schema.json"
                file.parent.mkdir(parents=True)
                schema = deepcopy(self.old)
                schema["$id"] = f"https://pulsestream.dev/contracts/{topic}/v1.schema.json"
                file.write_text(json.dumps(schema), encoding="utf-8")
            index = []
            for topic in contracts.TOPICS:
                fixture = root / f"contracts/fixtures/{topic}-v1.json"
                fixture.parent.mkdir(parents=True, exist_ok=True)
                fixture.write_text('{"version":"1.0"}', encoding="utf-8")
                index.append({"fixture": f"fixtures/{topic}-v1.json", "schema": f"schemas/{topic}/v1.schema.json"})
            index_file = root / "contracts/fixtures.json"
            index_file.write_text(json.dumps(index), encoding="utf-8")
            git("add", ".")
            git("-c", "user.name=Contract Test", "-c", "user.email=contracts@example.invalid", "-c", "commit.gpgsign=false",
                "commit", "--quiet", "-m", "Published contracts")
            self.assertEqual([], contracts.check(root, "HEAD"))
            major = deepcopy(self.old)
            major["$id"] = "https://pulsestream.dev/contracts/raw/v2.schema.json"
            major["properties"]["version"]["pattern"] = r"^2\.[0-9]+$"
            major["properties"]["payload"]["properties"]["value"] = {"type": "string"}
            (root / "contracts/schemas/raw/v2.schema.json").write_text(json.dumps(major), encoding="utf-8")
            (root / "contracts/fixtures/raw-v2.json").write_text('{"version":"2.0"}', encoding="utf-8")
            index.append({"fixture": "fixtures/raw-v2.json", "schema": "schemas/raw/v2.schema.json"})
            index_file.write_text(json.dumps(index), encoding="utf-8")
            self.assertEqual([], contracts.check(root, "HEAD"))
            old_file = root / "contracts/schemas/raw/v1.schema.json"
            old_file.write_text(json.dumps(major), encoding="utf-8")
            self.assertTrue(contracts.check(root, "HEAD"))
            old_file.unlink()
            self.assertTrue(any("removed" in error for error in contracts.check(root, "HEAD")))
            fixture.write_text('{}', encoding="utf-8")
            self.assertTrue(any("fixture changed" in error for error in contracts.check(root, "HEAD")))


if __name__ == "__main__":
    unittest.main()
