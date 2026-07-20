#!/usr/bin/env python3
"""Behavioral evidence checks that are too precise for shell token probes."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Iterable


EMPTY_EVIDENCE = (
    ".isEmpty()",
    ".isZero()",
    "recordsRead(0",
    "recordCount(0",
    "setRecordCount(0",
)
SYSTEM_FIELDS = (
    "_supa_synced",
    "_supa_deleted",
    "_supa_index",
    "_supa_id",
    "_supa_job_id",
)


def _strip_java_comments(text: str) -> str:
    """Remove Java comments without treating comment markers in strings as syntax."""
    result: list[str] = []
    index = 0
    state = "code"
    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if state == "code":
            if char == "/" and next_char == "/":
                state = "line_comment"
                result.extend((" ", " "))
                index += 2
                continue
            if char == "/" and next_char == "*":
                state = "block_comment"
                result.extend((" ", " "))
                index += 2
                continue
            result.append(char)
            if char == '"':
                state = "string"
            elif char == "'":
                state = "character"
            index += 1
            continue
        if state == "line_comment":
            if char == "\n":
                result.append(char)
                state = "code"
            else:
                result.append(" ")
            index += 1
            continue
        if state == "block_comment":
            if char == "*" and next_char == "/":
                result.extend((" ", " "))
                state = "code"
                index += 2
            else:
                result.append("\n" if char == "\n" else " ")
                index += 1
            continue

        result.append(char)
        if char == "\\" and next_char:
            result.append(next_char)
            index += 2
            continue
        if state == "string" and char == '"':
            state = "code"
        elif state == "character" and char == "'":
            state = "code"
        index += 1
    return "".join(result)


def _read(paths: Iterable[Path]) -> str:
    return "\n".join(path.read_text(encoding="utf-8") for path in paths)


def _java_files(root: Path, pattern: str = "*.java") -> list[Path]:
    if not root.exists():
        return []
    return sorted(root.rglob(pattern))


def _method_blocks(text: str, *, tests_only: bool = False) -> dict[str, str]:
    prefix = r"@Test\b[\s\S]{0,2000}?" if tests_only else ""
    method_re = re.compile(
        prefix
        + r"\b(?:public|protected|private|static|final|synchronized|\s)*"
        + r"(?:void|[\w<>, ?.\[\]]+)\s+(\w+)\s*\([^)]*\)"
        + r"(?:\s+throws[^{]+)?\s*\{",
        re.MULTILINE,
    )
    blocks: dict[str, str] = {}
    for match in method_re.finditer(text):
        start = match.end() - 1
        depth = 0
        for index in range(start, len(text)):
            char = text[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    blocks[match.group(1)] = text[match.start() : index + 1]
                    break
    return blocks


def _contains_empty_evidence(body: str) -> bool:
    return any(marker in body for marker in EMPTY_EVIDENCE)


def classify_connector(connector_dir: Path) -> dict[str, bool]:
    connector_text = _strip_java_comments(
        _read(_java_files(connector_dir / "src/main", "*Connector.java"))
    )
    methods = _method_blocks(connector_text)
    capability_body = methods.get("getConnectorCapabilities", "")
    config_body = methods.get("getCapabilitiesConfig", "")

    source = bool(re.search(r"\bREPLICATION_SOURCE\b", capability_body))
    destination = bool(
        re.search(
            r"\b(?:REPLICATION_DESTINATION|REVERSE_ETL_DESTINATION)\b",
            capability_body,
        )
    )
    activation = bool(
        re.search(r"\bREVERSE_ETL_DESTINATION\b", capability_body)
        or re.search(r"\b(?:asActivation|activationTarget)\b", config_body)
    )
    direct = bool(
        destination
        and not activation
        and (
            "asTraditionalDatabase" in config_body
            or "requiresStaging(false)" in config_body
        )
    )
    warehouse = bool(
        destination
        and not activation
        and (
            "asCloudWarehouse" in config_body
            or "requiresStaging(true)" in config_body
        )
    )
    if destination and not activation and not direct and not warehouse:
        stage_body = methods.get("stage", "")
        direct = bool(
            "StageResponse.noOp" in stage_body
            or "requiresStaging(false)" in connector_text
        )
        warehouse = not direct

    return {
        "source": source,
        "destination": destination,
        "activation": activation,
        "warehouse": warehouse,
        "direct": direct,
        "invalid_read": bool(
            re.search(r"\bConnectorCapabilities\.READ\b", capability_body)
        ),
        "invalid_write": bool(
            re.search(r"\bConnectorCapabilities\.WRITE\b", capability_body)
        ),
        "invalid_schema_discovery": bool(
            re.search(
                r"\bConnectorCapabilities\.SCHEMA_DISCOVERY\b",
                capability_body,
            )
        ),
    }


def _canonical_types(platform_root: Path) -> set[str]:
    candidates = sorted(platform_root.rglob("CanonicalType.java"))
    for path in candidates:
        text = path.read_text(encoding="utf-8")
        if "enum CanonicalType" not in text:
            continue
        match = re.search(r"enum\s+CanonicalType\s*\{(?P<body>[\s\S]*?)\}", text)
        if match:
            body = re.sub(r"//.*?$|/\*[\s\S]*?\*/", "", match.group("body"), flags=re.MULTILINE)
            enum_values = {
                value.group(1)
                for entry in body.split(",")
                if (value := re.search(r"\b([A-Z][A-Z0-9_]*)\b", entry))
            }
            if enum_values:
                return enum_values
    return {
        "JSON",
        "STRING",
        "DOUBLE",
        "FLOAT",
        "BIGDECIMAL",
        "LONG",
        "INT",
        "SHORT",
        "BOOLEAN",
        "INSTANT",
        "LOCALDATETIME",
        "LOCALDATE",
        "BINARY",
        "XML",
    }


def verify_cutoff_state(connector_dir: Path) -> list[str]:
    failures: list[str] = []
    test_text = _read(_java_files(connector_dir / "src/test"))
    test_methods = _method_blocks(test_text, tests_only=True)
    all_methods = _method_blocks(test_text)

    empty_initial = [
        body
        for body in test_methods.values()
        if "initialSync(true)" in body and _contains_empty_evidence(body)
    ]
    initial_proven = any(
        "getEndCursorPosition" in body
        and re.search(
            r"getEndCursorPosition\(\)[\s\S]{0,300}(?:\.isNull\(\)|assertNull\s*\()",
            body,
        )
        for body in empty_initial
    )
    if not initial_proven:
        failures.append(
            "Missing cutoff-state IT: an empty initial baseline must assert "
            "endCursorPosition is null"
        )

    empty_incremental = [
        body
        for body in test_methods.values()
        if "initialSync(false)" in body and _contains_empty_evidence(body)
    ]
    helper_bodies = "\n".join(
        body
        for name, body in all_methods.items()
        if re.search(r"cutoff|cursor|state", name, re.IGNORECASE)
    )
    incremental_proven = any(
        "cutoffTime(" in body
        and (
            (
                "getEndCursorPosition" in body
                and "getRecordCount" in body
                and re.search(r"getRecordCount\(\)[\s\S]{0,200}\.isNull\(\)", body)
            )
            or (
                re.search(r"assert\w*(?:Cutoff|Cursor|State)\w*\s*\(", body)
                and "getEndCursorPosition" in helper_bodies
                and "getValue" in helper_bodies
                and "getRecordCount" in helper_bodies
                and ".isNull()" in helper_bodies
            )
        )
        for body in empty_incremental
    )
    if not incremental_proven:
        failures.append(
            "Missing cutoff-state IT: an empty subsequent incremental window "
            "must assert end cursor equals cutoff and recordCount is null"
        )

    return failures


def _verify_all_types(
    connector_dir: Path,
    platform_root: Path,
    is_source: bool,
) -> list[str]:
    failures: list[str] = []
    all_types_files = [
        path
        for path in _java_files(connector_dir / "src/test", "*IT.java")
        if "alltypes" in re.sub(r"[^a-z0-9]", "", path.stem.lower())
    ]
    if not all_types_files:
        return [
            "Missing dedicated *AllTypes*IT.java; a generic CanonicalType reference "
            "does not prove a live round trip"
        ]

    text = _read(all_types_files)
    canonical_types = _canonical_types(platform_root)
    missing = sorted(
        canonical_type
        for canonical_type in canonical_types
        if f"CanonicalType.{canonical_type}" not in text
    )
    if missing:
        failures.append(
            "Dedicated all-types IT is missing canonical types: " + ", ".join(missing)
        )

    evidence = {
        "null-row assertions": "nullRecord" in text
        and ("\\\\N" in text or ".isNull()" in text or "NULL_PLACEHOLDER" in text),
        "decimal precision/scale assertions": "BigDecimal" in text
        and "getPrecision" in text
        and "getScale" in text,
        "microsecond temporal assertions": bool(
            re.search(r"\.\d{6}(?:Z|[\"'])", text)
        ),
        "semantic JSON assertions": "CanonicalType.JSON" in text
        and ("readTree" in text or "JsonNode" in text),
        "binary byte/Base64 assertions": "CanonicalType.BINARY" in text
        and re.search(r"Base64|TO_BASE64|FROM_BASE64|AAEC", text, re.IGNORECASE),
        "physical destination type assertions": "assertPhysicalTypes" in text
        or ("getSchema()" in text and "getType()" in text),
    }
    if is_source:
        evidence["hybrid source-path readback"] = bool(
            re.search(r"\.read\s*\(\s*ReadRequest|connector\.read\s*\(", text)
        )
    else:
        evidence["destination readback"] = bool(
            re.search(r"\bSELECT\b|query\s*\(", text, re.IGNORECASE)
        )

    for label, present in evidence.items():
        if not present:
            failures.append(f"Dedicated all-types IT lacks {label}")

    return failures


def _verify_system_fields(integration_test_text: str) -> list[str]:
    failures: list[str] = []
    missing = [
        field for field in SYSTEM_FIELDS if field not in integration_test_text
    ]
    if missing:
        return [
            "Destination IT is missing system-field assertions for: "
            + ", ".join(missing)
        ]

    schema_evidence = (
        "assertSystemFieldSchema" in integration_test_text
        or (
            "getSchema()" in integration_test_text
            and (
                "containsEntry" in integration_test_text
                or "getType()" in integration_test_text
            )
        )
    )
    if not schema_evidence:
        failures.append(
            "Destination IT must assert physical types for all five _supa_* fields"
        )

    value_evidence = (
        re.search(
            r"_supa_synced[\s\S]{0,500}(?:TIMESTAMP|Instant|syncTime)",
            integration_test_text,
        )
        and re.search(
            r"_supa_deleted[\s\S]{0,200}(?:FALSE|false)",
            integration_test_text,
        )
        and re.search(
            r"_supa_index[\s\S]{0,200}(?:=\s*1|isEqualTo\(1)",
            integration_test_text,
        )
        and re.search(
            r"_supa_job_id[\s\S]{0,500}(?:job|suffix)",
            integration_test_text,
            re.IGNORECASE,
        )
        and re.search(
            r"_supa_id[\s\S]{0,1000}(?:supaId|sha256|SupaflowSystemField)",
            integration_test_text,
            re.IGNORECASE,
        )
    )
    if not value_evidence:
        failures.append(
            "Destination IT must assert exact sync, delete, index, shared ID, and job ID values"
        )
    return failures


def _verify_merge_order(test_text: str, integration_test_text: str) -> list[str]:
    failures: list[str] = []
    merge_methods = [
        (name, body)
        for name, body in _method_blocks(test_text, tests_only=True).items()
        if re.search(r"merge|dedup", name, re.IGNORECASE)
    ]
    cursor_order = any(
        re.search(
            r"ORDER BY[\s\S]{0,500},[\s\S]{0,500}"
            r"_supa_synced[\s\S]{0,300}_supa_index",
            body,
            re.IGNORECASE,
        )
        and (
            "setCursorField(true)" in test_text
            or "cursor" in name.lower()
        )
        and " DESC" in body
        for name, body in merge_methods
    )
    fallback_order = any(
        re.search(
            r"(?:ORDER BY|isEqualTo\()[\s\S]{0,500}"
            r"_supa_synced[\s\S]{0,300}_supa_index",
            body,
            re.IGNORECASE,
        )
        and " DESC" in body
        for _, body in merge_methods
    )
    dedup_evidence = (
        any(
            re.search(r"PARTITION BY|ROW_NUMBER|dedup", body, re.IGNORECASE)
            for _, body in merge_methods
        )
        and cursor_order
        and fallback_order
    )
    if not dedup_evidence:
        failures.append(
            "Merge SQL tests must prove same-batch dedup ordering: business cursor, "
            "_supa_synced, then _supa_index"
        )

    live_merge = re.search(
        r"LoadMode\.MERGE[\s\S]{0,6000}(?:query|assertThat|isEqualTo)",
        integration_test_text,
        re.IGNORECASE,
    )
    if not live_merge:
        failures.append(
            "Destination IT must execute and assert a live MERGE path"
        )
    return failures


def _verify_discovery_mapping(
    connector_dir: Path,
    platform_root: Path,
) -> list[str]:
    mapper_tests = _java_files(connector_dir / "src/test", "*DataTypeMapperTest.java")
    if not mapper_tests:
        return [
            "Missing DataTypeMapper test documenting canonical-to-native and "
            "fresh-discovery mappings"
        ]
    text = _read(mapper_tests)
    missing = sorted(
        canonical_type
        for canonical_type in _canonical_types(platform_root)
        if f"CanonicalType.{canonical_type}" not in text
    )
    if (
        missing
        or "mapFromCanonicalType" not in text
        or not re.search(r"mapTypeByName|mapToCanonical", text)
        or not re.search(r"discover|readback|round.?trip", text, re.IGNORECASE)
    ):
        detail = f"; missing types: {', '.join(missing)}" if missing else ""
        return [
            "DataTypeMapper test must cover every canonical destination mapping and "
            f"document fresh-discovery widenings/collapses{detail}"
        ]
    return []


def _verify_json_conversion(
    connector_dir: Path,
    connector_text: str,
    is_source: bool,
) -> list[str]:
    if not is_source or "CanonicalType.JSON" not in connector_text:
        return []
    test_text = _read(_java_files(connector_dir / "src/test", "*Test.java"))
    if (
        "convertToCanonicalValue" in test_text
        and "CanonicalType.JSON" in test_text
        and re.search(r"\{\\?\"|readTree", test_text)
        and re.search(r"scalar|array|\[", test_text, re.IGNORECASE)
    ):
        return []
    return [
        "Hybrid JDBC JSON conversion needs a contract test proving object/array/scalar "
        "JSON text is not double-serialized"
    ]


def _verify_lossless_jdbc_source_projection(
    main_text: str,
    test_text: str,
    integration_test_text: str,
) -> list[str]:
    """Require source-side repair when standard JDBC values are already lossy."""
    handles_jdbc_struct = bool(
        re.search(
            r"\b(?:java\.sql\.)?Struct\b|ARRAY\s*<\s*STRUCT|"
            r"\b(?:STRUCT|RECORD)\s*<|TO_JSON_STRING",
            main_text,
            re.IGNORECASE,
        )
    )
    renders_source_projection = bool(
        re.search(r"\brenderSelectItem\s*\(", main_text)
    )
    handles_lossy_time = bool(
        renders_source_projection
        and re.search(r"[\"']TIME[\"']", main_text)
    )
    if not handles_jdbc_struct and not handles_lossy_time:
        return []

    failures: list[str] = []
    if handles_jdbc_struct:
        if not (
            renders_source_projection
            and "TO_JSON_STRING" in main_text
        ):
            failures.append(
                "A JDBC source that handles Struct values must project structured columns "
                "to lossless named JSON before ResultSet extraction"
            )

        raw_struct_rejected = bool(
            re.search(r"\bStruct\b", test_text)
            and re.search(r"assertThatThrownBy|assertThrows", test_text)
            and re.search(
                r"field.?names|positional|lossy|omit",
                test_text,
                re.IGNORECASE,
            )
        )
        if not raw_struct_rejected:
            failures.append(
                "JDBC source contract tests must reject raw Struct fallback instead of "
                "silently serializing positional attributes"
            )

        named_nested_readback = bool(
            re.search(
                r"JsonNode\s+(\w+)[\s\S]{0,1000}"
                r"\1\.(?:get|path)\s*\(\s*\"[^\"]+\"\s*\)",
                integration_test_text,
            )
            and re.search(
                r"STRUCT|RECORD|nested|field.?name",
                integration_test_text,
                re.IGNORECASE,
            )
        )
        if not named_nested_readback:
            failures.append(
                "Live JDBC source IT must parse structured output and assert named nested "
                "fields, not merely compare a JSON wrapper"
            )

    if handles_lossy_time:
        time_projection = bool(
            re.search(
                r"CAST\s*\([\s\S]{0,300}\bAS\s+STRING\s*\)",
                main_text,
                re.IGNORECASE,
            )
        )
        if not time_projection:
            failures.append(
                "A JDBC source whose driver truncates TIME precision must project TIME "
                "to a lossless source-native string"
            )
        microsecond_readback = bool(
            re.search(r"\d{2}:\d{2}:\d{2}\.\d{6}", integration_test_text)
            and re.search(
                r"event.?time|\bTIME\b|microsecond",
                integration_test_text,
                re.IGNORECASE,
            )
            and re.search(r"isEqualTo|containsEntry", integration_test_text)
        )
        if not microsecond_readback:
            failures.append(
                "Live JDBC source IT must assert exact six-digit TIME precision"
            )

    return failures


def _verify_bulk_metadata_parity_performance(
    main_text: str,
    integration_test_text: str,
) -> list[str]:
    bulk_metadata = bool(
        re.search(
            r"supportsBatchedSchemaFetch|JdbcBulkMetadata|BULK_INFORMATION_SCHEMA|"
            r"INFORMATION_SCHEMA\.(?:TABLES|COLUMNS)",
            main_text,
            re.IGNORECASE,
        )
    )
    if not bulk_metadata:
        return []

    failures: list[str] = []
    evidence = {
        "bulk fetch-path assertion": (
            re.search(
                r"BULK_INFORMATION_SCHEMA|bulk.?fetch.?path",
                integration_test_text,
                re.IGNORECASE,
            )
            and re.search(r"isEqualTo|containsExactly", integration_test_text)
        ),
        "tables-only/full object-set parity": (
            re.search(r"tables.?only", integration_test_text, re.IGNORECASE)
            and re.search(r"full.?(?:schema.?|catalog.?)?discovery|full.?metadata",
                          integration_test_text, re.IGNORECASE)
            and re.search(r"isEqualTo|containsExactlyInAnyOrder",
                          integration_test_text)
        ),
        "bounded metadata-query count": (
            re.search(r"metadata.?quer|query.?count",
                      integration_test_text, re.IGNORECASE)
            and "isLessThanOrEqualTo" in integration_test_text
        ),
        "catalog-scale elapsed-time budget": (
            "System.nanoTime" in integration_test_text
            and re.search(r"isLessThan\s*\(", integration_test_text)
        ),
        "positive field coverage": (
            re.search(r"field.?count|fields", integration_test_text,
                      re.IGNORECASE)
            and "isPositive" in integration_test_text
        ),
        "exact optional legacy parity": (
            re.search(r"System\.getenv|EnabledIfEnvironmentVariable",
                      integration_test_text)
            and re.search(r"assumeTrue|assumeFalse", integration_test_text)
            and re.search(r"legacy|base", integration_test_text,
                          re.IGNORECASE)
            and re.search(r"assertMetadataEqual|fieldDiffs|metadata.?diff",
                          integration_test_text, re.IGNORECASE)
        ),
        "bulk-only fail-fast performance path": (
            re.search(
                r"\w*(?:bulkOnly|bulk_only|failFast|fail_fast|disableFallback|"
                r"fallbackDisabled|withoutFallback)\w*\s*\(",
                main_text,
                re.IGNORECASE,
            )
            and re.search(
                r"\w*(?:bulkOnly|bulk_only|failFast|fail_fast|disableFallback|"
                r"fallbackDisabled|withoutFallback)\w*\s*\(",
                integration_test_text,
                re.IGNORECASE,
            )
        ),
    }
    for label, present in evidence.items():
        if not present:
            failures.append(
                "Bulk JDBC metadata IT lacks " + label
            )
    return failures


def verify_jdbc_source(connector_dir: Path) -> list[str]:
    main_files = _java_files(connector_dir / "src/main")
    main_text = _strip_java_comments(_read(main_files))
    classification = classify_connector(connector_dir)
    if not classification["source"] or "BaseJdbcConnector" not in main_text:
        return []

    test_text = _read(_java_files(connector_dir / "src/test", "*Test.java"))
    integration_test_text = _read(
        _java_files(connector_dir / "src/test", "*IT.java")
    )
    failures: list[str] = []
    failures.extend(
        _verify_lossless_jdbc_source_projection(
            main_text,
            test_text,
            integration_test_text,
        )
    )
    failures.extend(
        _verify_bulk_metadata_parity_performance(
            main_text,
            integration_test_text,
        )
    )
    return failures


def _verify_callback_and_error_artifacts(integration_test_text: str) -> list[str]:
    test_methods = _method_blocks(integration_test_text, tests_only=True)
    callback_asserted = any(
        re.search(r"assertThat\s*\([^)]*(?:callback|status)", body, re.IGNORECASE)
        and re.search(
            r"(?:success|error|input)(?:Row)?Count|getSuccessCount|getErrorCount",
            body,
            re.IGNORECASE,
        )
        for body in test_methods.values()
    )
    artifact_asserted = any(
        re.search(r"Files\.(?:readString|readAllLines|readAllBytes)", body)
        and re.search(r"assertThat\s*\(", body)
        and re.search(r"errorPath|error\.csv", body, re.IGNORECASE)
        for body in test_methods.values()
    )
    strict_and_moderate = (
        "ErrorHandling.STRICT" in integration_test_text
        and "ErrorHandling.MODERATE" in integration_test_text
    )
    bad_row = bool(
        re.search(
            r"bad.?row|invalid.?row|malformed|poison|rejected.?row|forced.?error",
            integration_test_text,
            re.IGNORECASE,
        )
    )
    failures: list[str] = []
    if not callback_asserted:
        failures.append(
            "Destination IT must assert callback input/success/error counts; "
            "collecting callback objects is not evidence"
        )
    if not artifact_asserted:
        failures.append(
            "Destination IT must read and assert the emitted error artifact; "
            "configuring errorPath is not evidence"
        )
    if not strict_and_moderate or not bad_row:
        failures.append(
            "Destination IT must force a bad row and prove both MODERATE and STRICT "
            "error-handling behavior"
        )
    return failures


def _verify_schema_evolution(integration_test_text: str) -> list[str]:
    evolution_methods = [
        body
        for name, body in _method_blocks(
            integration_test_text, tests_only=True
        ).items()
        if re.search(r"schema|evol|widen|type", name, re.IGNORECASE)
        or re.search(r"schema evolution|type change", body, re.IGNORECASE)
    ]
    additive = any(
        re.search(
            r"add(?:ed|itive)?.?column|contains\s*\(\s*\"[^\"]+\"\s*\)",
            body.split("{", 1)[-1],
            re.IGNORECASE,
        )
        for body in evolution_methods
    )
    type_change = any(
        re.search(
            r"type.?change|widen(?:ing|ed)?|changed.?type|"
            r"(?:INT64|INTEGER|FLOAT64|NUMERIC|DECIMAL)"
            r"[\s\S]{0,200}(?:STRING|NUMERIC|BIGNUMERIC|DECIMAL)",
            body.split("{", 1)[-1],
            re.IGNORECASE,
        )
        for body in evolution_methods
    )
    failures: list[str] = []
    if not additive:
        failures.append("Destination IT must prove additive schema evolution")
    if not type_change:
        failures.append(
            "Destination IT must prove a supported type-change/widening schema evolution"
        )
    return failures


def _verify_hard_delete(main_text: str, integration_test_text: str) -> list[str]:
    if not re.search(r"supportsHardDeletes\s*\(\s*true\s*\)", main_text):
        return []
    delete_proven = any(
        re.search(r"_supa_deleted[\s\S]{0,200}(?:TRUE|true)", body)
        and re.search(
            r"(?:isZero\s*\(|isEqualTo\s*\(\s*0|"
            r"doesNotContain\s*\(|isEmpty\s*\()",
            body,
        )
        for name, body in _method_blocks(
            integration_test_text, tests_only=True
        ).items()
        if re.search(r"delete|merge", name, re.IGNORECASE)
        or "_supa_deleted" in body
    )
    if delete_proven:
        return []
    return [
        "Connector advertises hard deletes, but no live IT writes "
        "_supa_deleted=true and asserts the target row is absent"
    ]


def _verify_physical_design(main_text: str, integration_test_text: str) -> list[str]:
    destructive = re.search(
        r"DROP TABLE|RENAME TO|WRITE_TRUNCATE|CREATE OR REPLACE|LoadMode\.OVERWRITE",
        main_text,
        re.IGNORECASE,
    )
    physical_design = re.search(
        r"Clustering|Partition|DISTKEY|SORTKEY|physical.?design",
        main_text,
        re.IGNORECASE,
    )
    if not destructive or not physical_design:
        return []

    preserved = False
    for body in _method_blocks(integration_test_text, tests_only=True).values():
        destructive_match = re.search(
            r"LoadMode\.(?:OVERWRITE|TRUNCATE_AND_LOAD)|DROP TABLE|WRITE_TRUNCATE",
            body,
            re.IGNORECASE,
        )
        if not destructive_match:
            continue
        after_destructive = body[destructive_match.start() :]
        if (
            re.search(
                r"getClustering|getPartition|DISTKEY|SORTKEY|physical.?design",
                after_destructive,
                re.IGNORECASE,
            )
            and re.search(
                r"assertThat[\s\S]{0,1000}(?:contains|isEqualTo)",
                after_destructive,
                re.IGNORECASE,
            )
        ):
            preserved = True
            break
    if preserved:
        return []
    return [
        "Destination IT must create user-owned physical-design metadata "
        "(clustering/partition/sort/distribution), run a destructive load path, "
        "and assert that metadata is preserved"
    ]


def _verify_concurrent_cold_schema(integration_test_text: str) -> list[str]:
    proven = any(
        re.search(r"concurrent|parallel|cold", name, re.IGNORECASE)
        and re.search(
            r"ExecutorService|CompletableFuture|CountDownLatch|invokeAll",
            body,
        )
        and re.search(
            r"new.?schema|new.?dataset|cold.?schema|CREATE SCHEMA|unique.?schema",
            body,
            re.IGNORECASE,
        )
        and re.search(r"assertThat|assertAll|assertDoesNotThrow", body)
        for name, body in _method_blocks(
            integration_test_text, tests_only=True
        ).items()
    )
    if proven:
        return []
    return [
        "Destination IT must run 2+ concurrent first loads into the same brand-new "
        "schema/dataset and assert all loads succeed"
    ]


def _verify_external_stage(
    connector_name: str,
    main_text: str,
    integration_test_text: str,
) -> list[str]:
    external_stage = re.search(
        r"gcsStagingBucket|s3StagingBucket|stagingBucket|bucketName",
        main_text,
        re.IGNORECASE,
    )
    if not external_stage:
        return []

    failures: list[str] = []
    if not re.search(r"stagingPrefix|jobDetailsId|job.?scoped", main_text, re.IGNORECASE):
        failures.append(
            "External object-storage staging must use a configured/job-scoped prefix"
        )
    if not re.search(
        r"deletePrefix|cleanup\w*Stage|cleanup\w*Gcs|storage\.delete|lifecycle",
        main_text,
        re.IGNORECASE,
    ):
        failures.append(
            "External object-storage staging needs explicit terminal cleanup and "
            "short-lifecycle backstop handling"
        )
    if not re.search(r"lifecycle|expiration|retention", main_text, re.IGNORECASE):
        failures.append(
            "External object-storage staging needs a bounded lifecycle/retention backstop"
        )
    if not re.search(
        r"assertPrefixClean|BlobListOption\.prefix[\s\S]{0,500}\.isEmpty\(\)",
        integration_test_text,
        re.IGNORECASE,
    ):
        failures.append(
            "External-stage IT must assert the job prefix is empty after cleanup"
        )
    failure_cleanup = any(
        re.search(r"fail|error|reject|malformed", name, re.IGNORECASE)
        and re.search(
            r"assertPrefixClean|lifecycle|expiration|retention",
            body,
            re.IGNORECASE,
        )
        for name, body in _method_blocks(
            integration_test_text, tests_only=True
        ).items()
    )
    if not failure_cleanup:
        failures.append(
            "External-stage IT must prove failure-path cleanup or explicitly retained "
            "diagnostics covered by the bounded lifecycle backstop"
        )

    if connector_name.lower() == "bigquery":
        missing_controls = [
            control
            for control in (
                "maximumBytesBilled",
                "jobTimeout",
                "expiration",
            )
            if control.lower() not in main_text.lower()
        ]
        if missing_controls:
            failures.append(
                "BigQuery live-test/runtime cost controls are missing: "
                + ", ".join(missing_controls)
            )

    return failures


def verify_warehouse(connector_dir: Path, platform_root: Path) -> list[str]:
    main_files = _java_files(connector_dir / "src/main")
    connector_files = [
        path for path in main_files if path.name.endswith("Connector.java")
    ]
    main_text = _read(main_files)
    connector_text = _read(connector_files)
    test_text = _read(_java_files(connector_dir / "src/test"))
    integration_test_text = _read(
        _java_files(connector_dir / "src/test", "*IT.java")
    )
    classification = classify_connector(connector_dir)
    failures: list[str] = []
    failures.extend(
        _verify_all_types(
            connector_dir,
            platform_root,
            classification["source"],
        )
    )
    failures.extend(_verify_system_fields(integration_test_text))
    failures.extend(_verify_merge_order(test_text, integration_test_text))
    failures.extend(_verify_discovery_mapping(connector_dir, platform_root))
    failures.extend(
        _verify_json_conversion(
            connector_dir,
            connector_text,
            classification["source"],
        )
    )
    failures.extend(_verify_callback_and_error_artifacts(integration_test_text))
    failures.extend(_verify_schema_evolution(integration_test_text))
    failures.extend(_verify_hard_delete(main_text, integration_test_text))
    failures.extend(_verify_physical_design(main_text, integration_test_text))
    failures.extend(_verify_concurrent_cold_schema(integration_test_text))
    failures.extend(
        _verify_external_stage(
            connector_dir.name.removeprefix("supaflow-connector-"),
            main_text,
            integration_test_text,
        )
    )
    return failures


def verify(check: str, connector_name: str, platform_root: Path) -> list[str]:
    connector_dir = (
        platform_root / "connectors" / f"supaflow-connector-{connector_name}"
    )
    if check == "cutoff-state":
        return verify_cutoff_state(connector_dir)
    if check == "jdbc-source":
        return verify_jdbc_source(connector_dir)
    if check == "warehouse":
        return verify_warehouse(connector_dir, platform_root)
    raise ValueError(f"Unknown check: {check}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "check",
        choices=("classify", "cutoff-state", "jdbc-source", "warehouse"),
    )
    parser.add_argument("connector_name")
    parser.add_argument("platform_root", type=Path)
    args = parser.parse_args()

    platform_root = args.platform_root.resolve()
    if args.check == "classify":
        connector_dir = (
            platform_root
            / "connectors"
            / f"supaflow-connector-{args.connector_name}"
        )
        for name, enabled in classify_connector(connector_dir).items():
            print(f"{name}={'true' if enabled else 'false'}")
        return 0

    failures = verify(args.check, args.connector_name, platform_root)
    for failure in failures:
        print(f"FAIL: {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
