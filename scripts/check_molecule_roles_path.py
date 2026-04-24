#!/usr/bin/env python3
"""Validate ANSIBLE_ROLES_PATH in all molecule.yml files.

Known patterns and their expected values:
  roles/<name>/molecule/<scenario>/molecule.yml -> ../../../../roles
  molecule/<scenario>/molecule.yml             -> ../../roles
"""

import os
import sys
import pathlib

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML not installed. Run: pip install pyyaml")
    sys.exit(2)

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

PATTERNS = {
    # (parts from repo root): expected ANSIBLE_ROLES_PATH
    4: {
        # roles/<name>/molecule/<scenario>/molecule.yml
        "check": lambda parts: parts[0] == "roles" and parts[2] == "molecule",
        "expected": "../../../../roles",
        "description": "roles/<name>/molecule/<scenario>/molecule.yml",
    },
    2: {
        # molecule/<scenario>/molecule.yml
        "check": lambda parts: parts[0] == "molecule",
        "expected": "../../roles",
        "description": "molecule/<scenario>/molecule.yml",
    },
}


def get_expected_path(rel_path: pathlib.Path):
    """Return expected ANSIBLE_ROLES_PATH for a given molecule.yml relative path."""
    parts = rel_path.parts[:-1]  # strip the filename itself
    depth = len(parts)
    pattern = PATTERNS.get(depth)
    if pattern and pattern["check"](parts):
        return pattern["expected"], pattern["description"]
    return None, None


def check_molecule_file(mol_path: pathlib.Path):
    """Return (passed, message) for a single molecule.yml file."""
    rel = mol_path.relative_to(REPO_ROOT)
    expected, description = get_expected_path(rel)

    if expected is None:
        return False, f"UNKNOWN PATTERN: {rel} — cannot determine expected ANSIBLE_ROLES_PATH"

    try:
        with open(mol_path) as f:
            data = yaml.safe_load(f)
    except Exception as e:
        return False, f"PARSE ERROR: {rel} — {e}"

    try:
        declared = data["provisioner"]["env"]["ANSIBLE_ROLES_PATH"]
    except (TypeError, KeyError):
        return False, f"MISSING: {rel} — provisioner.env.ANSIBLE_ROLES_PATH not set"

    if declared == expected:
        return True, f"PASS: {rel} ({description}) — {declared!r}"
    else:
        return False, (
            f"FAIL: {rel} ({description}) — "
            f"declared {declared!r} but expected {expected!r}"
        )


def main():
    mol_files = sorted(REPO_ROOT.rglob("molecule.yml"))
    if not mol_files:
        print("ERROR: no molecule.yml files found under", REPO_ROOT)
        sys.exit(1)

    results = [check_molecule_file(f) for f in mol_files]

    for _, msg in results:
        print(msg)

    failures = [msg for passed, msg in results if not passed]
    if failures:
        print(f"\n{len(failures)} check(s) failed.")
        sys.exit(1)
    else:
        print(f"\nAll {len(results)} molecule.yml file(s) passed.")
        sys.exit(0)


if __name__ == "__main__":
    main()
