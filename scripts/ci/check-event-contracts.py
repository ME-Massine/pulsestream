"""Conservative event-contract evolution gate; no network or third-party packages.

Same-major edits may add optional properties and edit annotations. All existing
validation rules and fields must remain intact. This deliberately rejects some
safe changes rather than guessing JSON Schema subsumption from sample payloads.
"""

import argparse
from decimal import Decimal
import json
from pathlib import Path
import re
import subprocess
import sys


ANNOTATIONS = {"title", "description", "$comment", "examples", "deprecated"}
SCHEMA_PATH = re.compile(r"contracts/schemas/([a-z-]+)/v([1-9][0-9]*)\.schema\.json$")
TOPICS = {"raw", "processed", "anomaly", "dead-letter"}


def json_equal(left, right):
    """Compare JSON values recursively, keeping booleans distinct from numbers."""
    if isinstance(left, bool) or isinstance(right, bool):
        return type(left) is type(right) and left == right
    if isinstance(left, dict):
        return isinstance(right, dict) and left.keys() == right.keys() and all(
            json_equal(value, right[key]) for key, value in left.items())
    if isinstance(left, list):
        return isinstance(right, list) and len(left) == len(right) and all(
            json_equal(before, after) for before, after in zip(left, right))
    return left == right


def compare(old, new, path="$"):
    """Return all unsupported same-major changes, including unknown keywords."""
    if not isinstance(old, dict) or not isinstance(new, dict):
        return [] if json_equal(old, new) else [f"{path}: validation rule changed"]
    errors = []
    for key in old.keys() | new.keys():
        if key in ANNOTATIONS:
            continue
        before, after = old.get(key), new.get(key)
        if key in {"properties", "$defs"} and isinstance(before, dict) and isinstance(after, dict):
            for name, rule in before.items():
                if name not in after:
                    errors.append(f"{path}/{key}/{name}: existing field/definition removed")
                else:
                    errors.extend(compare(rule, after[name], f"{path}/{key}/{name}"))
            if key == "properties" and after.keys() - before.keys():
                if old.get("additionalProperties") is not True:
                    errors.append(f"{path}: optional additions require an open object")
        elif key == "required":
            if set(before or []) != set(after or []):
                errors.append(f"{path}/required: required fields changed")
        elif key not in old or key not in new:
            errors.append(f"{path}/{key}: validation keyword added/removed")
        elif key in {"items", "additionalProperties", "contains", "propertyNames", "not", "if", "then", "else"} \
                and isinstance(before, dict) and isinstance(after, dict):
            errors.extend(compare(before, after, f"{path}/{key}"))
        elif not json_equal(before, after):
            errors.append(f"{path}/{key}: validation rule changed")
    return errors


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True, encoding="utf-8")


def check(root, base_ref):
    current = {}
    errors = []
    for file in sorted((root / "contracts/schemas").rglob("*.json")):
        relative = file.relative_to(root).as_posix()
        match = SCHEMA_PATH.fullmatch(relative)
        if not match or match[1] not in TOPICS:
            errors.append(f"{relative}: expected a known topic and v<major>.schema.json")
            continue
        schema = json.loads(file.read_text(encoding="utf-8"), parse_float=Decimal)
        current[relative] = schema
        expected_id = f"https://pulsestream.dev/contracts/{match[1]}/v{match[2]}.schema.json"
        if schema.get("$id") != expected_id:
            errors.append(f"{relative}: $id must be {expected_id}")
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            errors.append(f"{relative}: Draft 2020-12 is required")
        expected_version = {"type": "string", "pattern": rf"^{match[2]}\.[0-9]+$"}
        version = dict(schema.get("properties", {}).get("version", {}))
        version.pop("default", None)
        for annotation in ANNOTATIONS:
            version.pop(annotation, None)
        if version != expected_version:
            errors.append(f"{relative}: version must map to schema major {match[2]}")
        if schema.get("additionalProperties") is not True:
            errors.append(f"{relative}: unknown optional envelope fields must be accepted")
    for topic in TOPICS:
        if f"contracts/schemas/{topic}/v1.schema.json" not in current:
            errors.append(f"{topic}: missing v1 contract")

    index = json.loads((root / "contracts/fixtures.json").read_text(encoding="utf-8"))
    indexed_fixtures = set()
    covered_schemas = set()
    for entry in index:
        fixture, schema = entry["fixture"], entry["schema"]
        if not re.fullmatch(r"fixtures/[a-z0-9-]+\.json", fixture):
            errors.append(f"{fixture}: fixture must be a JSON file directly under contracts/fixtures")
        if fixture in indexed_fixtures:
            errors.append(f"{fixture}: duplicate fixture registration")
        indexed_fixtures.add(fixture)
        covered_schemas.add("contracts/" + schema)
        if "contracts/" + schema not in current:
            errors.append(f"{schema}: fixture references an unknown schema")
    actual_fixtures = {f.relative_to(root / "contracts").as_posix()
                       for f in (root / "contracts/fixtures").rglob("*.json")}
    if indexed_fixtures != actual_fixtures:
        errors.append("fixtures.json must register every shared fixture exactly once")
    if covered_schemas != current.keys():
        errors.append("fixtures.json must cover every supported schema major")

    # Validate the ref even on the first schema-bearing PR. Never silently turn a
    # failed fetch / unknown ref into a successful compatibility check.
    git(root, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
    previous = git(root, "ls-tree", "-r", "--name-only", base_ref, "--", "contracts/schemas")
    for relative in previous.splitlines():
        if not relative.endswith(".schema.json"):
            continue
        if relative not in current:
            errors.append(f"{relative}: published schema removed; retain old majors during migration")
            continue
        old = json.loads(git(root, "show", f"{base_ref}:{relative}"), parse_float=Decimal)
        errors.extend(f"{relative}: {error}" for error in compare(old, current[relative]))

    # Existing examples are compatibility promises too; replacing the examples
    # must not make a breaking schema look compatible.
    old_fixtures = git(root, "ls-tree", "-r", "--name-only", base_ref, "--", "contracts/fixtures")
    for relative in old_fixtures.splitlines():
        file = root / relative
        if not file.is_file() or not json_equal(
                json.loads(file.read_text(encoding="utf-8"), parse_float=Decimal),
                json.loads(git(root, "show", f"{base_ref}:{relative}"), parse_float=Decimal)):
            errors.append(f"{relative}: published fixture changed/removed; add a new fixture")
    if "contracts/fixtures.json" in git(root, "ls-tree", "-r", "--name-only", base_ref,
                                       "--", "contracts/fixtures.json").splitlines():
        old_index = json.loads(git(root, "show", f"{base_ref}:contracts/fixtures.json"))
        for entry in old_index:
            if entry not in index:
                errors.append(f"{entry}: published fixture/schema registration changed/removed")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-ref", required=True, help="PR base SHA or previous push SHA")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        errors = check(args.root.resolve(), args.base_ref)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Contract check failed: {error}", file=sys.stderr)
        return 1
    if errors:
        print("Contract evolution requires a new major schema (retain the old major):", file=sys.stderr)
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Event contract compatibility passed against {args.base_ref}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
