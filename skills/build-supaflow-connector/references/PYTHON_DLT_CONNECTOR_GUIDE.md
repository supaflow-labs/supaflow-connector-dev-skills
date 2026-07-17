# Python/dlt Source Connector Guide

Use this track for connectors under
`python/connectors/supaflow_connector_<name>/` that extend
`DeclarativeDltConnector`. It replaces the Java-oriented phases 1-6.

## Required Reading

Read these platform files before implementation:

- `python/supaflow_dlt_runtime/declarative.py`: `DeclarativeDltConnector`,
  `_compute_selected_fields`, and all read paths.
- `python/tests/harness/read_harness.py`: `selected_fields_factory` and exact
  CSV projection checks.
- `python/connectors/supaflow_connector_bolddesk/`: first-party dlt source
  packaging and adapter structure. Treat it as structure guidance, not proof
  that every runtime contract is already implemented.
- A connector that already implements source projection, such as Jira or
  Google Ads.

Do not add import-time `sys.modules` mutations or runtime configuration in
`prepare_imports()`/`conftest.py`. Runtime configuration belongs in
`DeclarativeDltConnector._create_source` or `_configure_dlt_source`.

## Package Contract

Keep source and adapter responsibilities separate:

- `connector.py`: Supaflow configuration, schema contract, sync-state bridge,
  effective field selection, and source construction.
- Source package: API calls, pagination, normalization, partial-response
  masks, and connector-independent dlt resources.
- `object_schemas.py` or equivalent: declared fields, static fields, dlt hints,
  and projection helpers.
- Unit tests: adapter/source behavior with fake clients.
- Integration tests: SDK `ReadHarness`, schema discovery, initial read, and
  incremental round trip.

## Field-Selection Contract

Field selection is mandatory behavior, not an optimization.

1. Discovery returns the complete committed schema. It must not depend on the
   last read's selected fields.
2. `_compute_selected_fields` returns `None` when no field has an explicit
   selection. `None` means fetch the default/full projection.
3. A concrete set, including an empty set, is authoritative. Never use
   `selected_fields or all_fields`; that converts an explicit empty selection
   into a full read.
4. `_create_source(..., selected_fields=...)` must consume the argument and
   pass the effective projection into the source. Merely accepting the
   parameter is a contract failure.
5. Keep the minimum operational floor required for correctness: root primary
   keys, connector-managed cursor fields, source fields needed to calculate
   deletion state, and fields needed for source-side scoping. Pagination and
   sync tokens stay in API response masks but are not emitted as business
   columns.
6. `_supa_id` is framework-owned. `_supa_deleted` and other required system
   fields must survive projection when the connector emits them.
7. If the API supports field masks or projections, request only selected plus
   operational source fields. Translate derived output fields to their parent
   API paths (for example, `creatorEmail` may require `creator`).
8. Filter normalized records and dlt column hints. Filtering records alone is
   insufficient because full hints can recreate deselected columns with null
   values during normalize.
9. Apply the same projection to initial and incremental paths. Token-based
   incremental calls often use a different request shape and must be tested
   separately.

Canonical adapter shape:

```python
REQUIRED_READ_FIELDS = {
    "objects": frozenset({"id", "updated_at"}),
}

def _create_source(
    self,
    resource,
    cutoff_time=None,
    effective_start=None,
    selected_fields=None,
    selected_child_objects=None,
):
    effective = None
    if selected_fields is not None:
        effective = frozenset(
            (selected_fields & declared_field_names(resource.name))
            | REQUIRED_READ_FIELDS.get(resource.name, frozenset())
        )
    source = connector_source(
        endpoints=(resource.name,),
        selected_fields=effective,
    )
    source.resources[resource.name].apply_hints(
        columns=to_dlt_column_hints(resource.name, effective)
    )
    return source
```

The source must use `effective` for API projection and final row projection.
Do not silently fall back to all fields when a selected field is unknown;
intersect with the declared schema and retain only the operational floor.

## Required Field-Selection Tests

Every Python/dlt source connector must have all three layers below.

### Adapter unit test

Patch the source factory, call `_create_source` with a sparse set, and assert
the source receives exactly the selected declared fields plus the documented
identity/cursor floor. Include `_supa_id` in the input to prove it is not sent
to the vendor API.

### Source unit test

Use a fake client with at least one selected and one deselected field. Assert:

- emitted row keys equal selected plus required system fields;
- dlt resource hint keys equal the same projection;
- the selected vendor field is present in the API field mask;
- the deselected vendor field is absent from the mask and row;
- initial and incremental/token calls both use the projection;
- derived fields request the correct parent API path.

### SDK/read-harness integration test

Use a narrow metadata factory:

```python
def selected_fields(obj):
    keep = {"_supa_id", "id", "updated_at", "name"}
    return [
        MetadataField(
            name=field.name,
            canonical_type=field.canonical_type,
            selected=True,
        )
        for field in obj.fields
        if field.name in keep
    ]

ReadHarness(
    Connector,
    config,
    resources=["objects"],
    selected_fields_factory=selected_fields,
    require_hex_64_supa_id=True,
    validate_typed_encoding=True,
).run_all(tmp_path)
```

`ReadHarness` validates the emitted CSV header and row projection. Also retain
an incremental round-trip test using the same source projection, or a source
unit test that explicitly exercises both baseline and saved-token states.

## Verification

Run the connector tests and the skill verifier:

```bash
cd "$PLATFORM_ROOT"
python/.venv/bin/python -m pytest \
  python/tests/test_<name>_connector.py \
  python/tests/test_<name>_source.py \
  python/tests/integration/test_<name>_read_harness_e2e.py -q

bash "$SKILL_ROOT/scripts/verify_connector.sh" <name> "$PLATFORM_ROOT"
```

The verifier must reject a connector when `_create_source` ignores
`selected_fields`, when no source-level projection regression exists, or when
no `ReadHarness(selected_fields_factory=...)` integration test exists.

