#!/usr/bin/env python3
"""Validate ANSIBLE_ROLES_PATH in all molecule.yml files.

Known patterns and their expected values:
  roles/<name>/molecule/<scenario>/molecule.yml -> ../../../../roles
  molecule/<scenario>/molecule.yml             -> ../../roles
"""

import sys
import pathlib

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML not installed. Run: pip install pyyaml")
    sys.exit(2)

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent


def get_expected_path(rel_path: pathlib.Path):
    """Return expected ANSIBLE_ROLES_PATH for a given molecule.yml relative path."""
    parts = rel_path.parts[:-1]  # strip the filename itself
    if len(parts) == 4 and parts[0] == "roles" and parts[2] == "molecule":
        return "../../../../roles", "roles/<name>/molecule/<scenario>/molecule.yml"
    if len(parts) == 2 and parts[0] == "molecule":
        return "../../roles", "molecule/<scenario>/molecule.yml"
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

    failures = 0
    for f in mol_files:
        passed, msg = check_molecule_file(f)
        print(msg)
        if not passed:
            failures += 1

    if failures:
        print(f"\n{failures} check(s) failed.")
        sys.exit(1)
    print(f"\nAll {len(mol_files)} molecule.yml file(s) passed.")
    sys.exit(0)


if __name__ == "__main__":
    main()
