#!/usr/bin/env python3
"""Verify the minimum Python/dlt connector and field-selection contract."""

from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path


def _normalized_name(raw: str) -> str:
    name = raw.strip().lower().replace("-", "_")
    prefix = "supaflow_connector_"
    return name[len(prefix) :] if name.startswith(prefix) else name


def _base_name(node: ast.expr) -> str:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    return ""


def _connector_class(tree: ast.Module) -> ast.ClassDef | None:
    for node in tree.body:
        if not isinstance(node, ast.ClassDef):
            continue
        if any(_base_name(base) == "DeclarativeDltConnector" for base in node.bases):
            return node
    return None


def _method(class_node: ast.ClassDef, name: str) -> ast.FunctionDef | None:
    for node in class_node.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    return None


def _method_arg_names(method: ast.FunctionDef) -> set[str]:
    return {
        arg.arg
        for arg in (
            list(method.args.posonlyargs)
            + list(method.args.args)
            + list(method.args.kwonlyargs)
        )
    }


def _loads_name(method: ast.FunctionDef, name: str) -> bool:
    return any(
        isinstance(node, ast.Name)
        and node.id == name
        and isinstance(node.ctx, ast.Load)
        for node in ast.walk(method)
    )


def _candidate_tests(platform_root: Path, name: str) -> list[Path]:
    tests_root = platform_root / "python" / "tests"
    return sorted(path for path in tests_root.rglob(f"*{name}*.py") if path.is_file())


def verify(connector_name: str, platform_root: Path) -> list[str]:
    """Return contract failures. An empty list means the gate passed."""
    name = _normalized_name(connector_name)
    connector_file = (
        platform_root
        / "python"
        / "connectors"
        / f"supaflow_connector_{name}"
        / "connector.py"
    )
    failures: list[str] = []
    if not connector_file.is_file():
        return [f"Python connector file not found: {connector_file}"]

    try:
        tree = ast.parse(connector_file.read_text("utf-8"), filename=str(connector_file))
    except SyntaxError as exc:
        return [f"Cannot parse {connector_file}: {exc}"]

    class_node = _connector_class(tree)
    if class_node is None:
        failures.append("No class extending DeclarativeDltConnector was found")
    else:
        create_source = _method(class_node, "_create_source")
        if create_source is None:
            failures.append("Connector must override _create_source")
        else:
            if "selected_fields" not in _method_arg_names(create_source):
                failures.append("_create_source must accept selected_fields")
            elif not _loads_name(create_source, "selected_fields"):
                failures.append(
                    "_create_source accepts selected_fields but never consumes it"
                )

    test_files = _candidate_tests(platform_root, name)
    if not test_files:
        failures.append(f"No connector tests found with {name!r} in the filename")
        return failures

    unit_text = "\n".join(
        path.read_text("utf-8")
        for path in test_files
        if "integration" not in path.parts
    )
    integration_text = "\n".join(
        path.read_text("utf-8")
        for path in test_files
        if "integration" in path.parts
    )

    has_projection_unit = (
        "selected_fields" in unit_text
        and ("not in" in unit_text or "set(row)" in unit_text)
        and ("incremental" in unit_text or "sync_token" in unit_text)
    )
    if not has_projection_unit:
        failures.append(
            "Missing source/adapter unit coverage that consumes selected_fields, "
            "asserts a deselected field is absent, and exercises incremental/token state"
        )

    has_harness_projection = "selected_fields_factory" in integration_text
    has_equivalent_live_projection = (
        "field_pushdown" in integration_text
        and "deselected" in integration_text
        and "not in" in integration_text
    )
    if not (has_harness_projection or has_equivalent_live_projection):
        failures.append(
            "Missing live/read-harness sparse projection coverage; use "
            "ReadHarness(selected_fields_factory=...) and assert deselected fields are absent"
        )

    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("connector_name")
    parser.add_argument("platform_root", type=Path)
    args = parser.parse_args(argv)

    platform_root = args.platform_root.expanduser().resolve()
    failures = verify(args.connector_name, platform_root)
    print("===================================================================")
    print("  Supaflow Python/dlt Connector Verification")
    print("===================================================================")
    print(f"Connector: {_normalized_name(args.connector_name)}")
    print(f"Platform: {platform_root}")
    if failures:
        for failure in failures:
            print(f"ERROR: {failure}")
        print(f"FAILED: {len(failures)} contract violation(s)")
        return 1

    print("PASS: DeclarativeDltConnector layout detected")
    print("PASS: _create_source consumes selected_fields")
    print("PASS: source/adapter projection regression detected")
    print("PASS: live/read-harness sparse projection regression detected")
    return 0


if __name__ == "__main__":
    sys.exit(main())

