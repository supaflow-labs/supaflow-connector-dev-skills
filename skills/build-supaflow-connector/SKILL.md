---
name: build-supaflow-connector
description: Build or review Java and Python/dlt Supaflow connectors using a phased workflow for source connectors, structured destinations, and activation targets. Use this skill when implementing a new connector, debugging connector reads or field selection, adding incremental sync, or validating connector quality in a Supaflow platform repository with executable gates and anti-pattern enforcement.
---

# Build Supaflow Connector

Build connectors phase-by-phase, enforce verification gates before moving forward, and apply hard guardrails from anti-pattern documentation.

## Collect Inputs First

- `platform_root`: absolute path to a Supaflow platform repo clone containing `pom.xml` and `connectors/`
- `connector_name`: directory/module suffix (for example, `airtable`)
- `connector_mode`: `source`, `destination-database`, `destination-warehouse`, `destination-activation`, or `hybrid`
- `implementation_track`: `python-dlt`, `java-jdbc`, or `java-api`
- `connector_base`: `jdbc` if JDBC-based (extends BaseJdbcConnector), otherwise `api` (Java compatibility input)
- `auth_type`: API key, OAuth client credentials, OAuth auth code, or custom
- `api_surface`: object endpoints, pagination model, rate limits, and date/cursor fields
- `test_credentials`: required env vars and sandbox/test account scope

If the task also includes customer-facing connector docs or marketing pages in `supaflow-www`, you must also load `references/CONNECTOR_DOCS_MARKETING.md` before drafting or reviewing them.

## Phase 0: Mandatory Reading (Do This First, No Exceptions)

Before writing any code, read these files in full. Do not skip this step. Do not summarize or skim.

1. `references/ANTI_PATTERNS.md` -- learn what NOT to do
2. `references/README.md` -- understand phase structure and gate checks
3. `references/PORTABILITY.md` -- understand path and reference variables

### Phase 0 Gate (Required Before Any Code Changes)

Run and show output for these commands before editing connector code:

```bash
SKILL_ROOT="<abs-path-to-this-skill-folder>"
PLATFORM_ROOT="<abs-path-to-platform-repo>"
CONNECTOR_NAME="<connector-name>"

sed -n '1,220p' "$SKILL_ROOT/references/ANTI_PATTERNS.md"
sed -n '1,220p' "$SKILL_ROOT/references/README.md"
sed -n '1,220p' "$SKILL_ROOT/references/PORTABILITY.md"
rg -n "class BaseJdbcConnector|convertToCanonicalValue\\(|mapTypeByName\\(" \
  "$PLATFORM_ROOT/connectors" -g"*.java"
```

For the Python/dlt track, replace the final Java search with:

```bash
rg -n "class DeclarativeDltConnector|def _compute_selected_fields|selected_fields_factory" \
  "$PLATFORM_ROOT/python" -g"*.py"
```

Do not modify connector files until the Phase 0 gate output is shown.

If your session context was compacted or you lost prior instructions, re-read this SKILL.md and repeat Phase 0 before continuing.

## Detect Connector Base

Detect the implementation track from the target path before choosing phase docs:

- `python/connectors/supaflow_connector_<name>/`: follow the **Python/dlt track** in `references/PYTHON_DLT_CONNECTOR_GUIDE.md`.
- `connectors/supaflow-connector-<name>/` extending `BaseJdbcConnector`: follow the **Java JDBC track**.
- Other `connectors/supaflow-connector-<name>/` modules: follow the **Java API track**.

If the connector is JDBC-based (`connector_base: jdbc`), follow the **JDBC track**:
- Phases 1, 2: same as API track
- Phases 3, 4, 5: replaced by `references/JDBC_CONNECTOR_GUIDE.md`
- Phase 7: add only if the JDBC connector is also a structured destination (for example PostgreSQL or SQL Server)
- Phase 6: same as API track (integration testing)

If the connector is API-based (REST, SOAP, GraphQL), follow the standard phase track below.

## Choose Track

- `source`: complete phases `1 -> 6` (or `1, 2, JDBC guide, 6` for JDBC connectors)
- `destination-database`: complete phases `1 -> 4`, then `7`, then destination tests/checks (or `1, 2, JDBC guide, 7, 6` for JDBC connectors)
- `destination-warehouse`: complete phases `1 -> 4`, then `7`, then destination tests/checks
- `destination-activation`: complete phases `1 -> 4`, then `8`, then destination tests/checks
- `hybrid`: combine the source track with the applicable destination track. Use Phase 7 for structured database/warehouse/file destinations and Phase 8 only for activation/API destinations.
- `python-dlt` source: complete `references/PYTHON_DLT_CONNECTOR_GUIDE.md`; do not apply Java-only class or Maven requirements

## Load Phase Docs by Need

Load only the current phase doc. For JDBC connectors, load `references/JDBC_CONNECTOR_GUIDE.md` instead of phases 3-5.

- `references/PHASE_1_PROJECT_SETUP.md`
- `references/PHASE_2_CONNECTOR_IDENTITY.md`
- `references/PHASE_3_CONNECTION_AUTH.md` (API connectors only)
- `references/PHASE_4_SCHEMA_DISCOVERY.md` (API connectors only)
- `references/PHASE_5_READ_OPERATIONS.md` (API connectors only)
- `references/JDBC_CONNECTOR_GUIDE.md` (JDBC connectors: replaces phases 3-5)
- `references/PYTHON_DLT_CONNECTOR_GUIDE.md` (Python/dlt sources: replaces Java phases 1-6)
- `references/PHASE_6_INTEGRATION_TESTING.md`
- `references/PHASE_7_WRITE_OPERATIONS.md`
- `references/PHASE_8_ACTIVATION_TARGETS.md`

## Phase Protocol (Do Not Skip)

1. Read the phase doc prerequisites and required core classes.
2. Implement only the current phase scope.
3. Run the phase gate checks and show command output.
4. Fix failures for the current phase's listed checks. The verifier is also a final-state gate, so failures from later phases are expected until those phases are implemented.
5. Proceed to the next phase only after the current phase is clean.

## Required Commands

Use the bundled verification script from this skill package.

```bash
PLATFORM_ROOT="<abs-path-to-platform-repo>"
SKILL_ROOT="<abs-path-to-this-skill-folder>"

# Build connector module quickly during iteration
cd "$PLATFORM_ROOT"
mvn -pl connectors/supaflow-connector-<connector_name> -am -DskipTests clean install

# Gate verification. During phased work, use the phase docs' listed checks as the
# gate; at final handoff, all applicable verifier checks must pass.
bash "$SKILL_ROOT/scripts/verify_connector.sh" <connector_name> "$PLATFORM_ROOT"
```

For Python/dlt connectors, use the platform development venv for tests; the
same verifier auto-detects the Python connector layout:

```bash
cd "$PLATFORM_ROOT"
python/.venv/bin/python -m pytest <connector-unit-and-integration-tests> -q
bash "$SKILL_ROOT/scripts/verify_connector.sh" <connector_name> "$PLATFORM_ROOT"
```

Use full-repo build when dependency graph changes:

```bash
mvn clean install
```

## Hard Guardrails

- Never call `processor.close()` manually in `read()`.
- Always set `originalDataType` on every `FieldMetadata`.
- Always choose incremental state by source capability, not by connector base class. If a
  time-based source can enforce an exclusive upper bound (`cursor < cutoffTime`), it MUST use a
  cutoff-time window and persist the cutoff without `recordCount`; this includes JDBC connectors,
  which must opt into the base cutoff hook instead of inheriting the count-based fallback. Use
  boundary counts only when the source cannot enforce a reliable upper cutoff.
- Treat initial and subsequent empty cutoff windows differently. An empty initial baseline MUST
  return no end cursor so bootstrap remains initial. An empty subsequent incremental window MUST
  advance to the supplied cutoff with `recordCount == null`. Enforce this in shared SDK behavior
  and prove both cases in connector IT; do not add a connector-local cursor workaround.
- Never treat cursor position as a single scalar; respect incremental field structures.
- Always run cursor identification (`identifyCursorFields()` or equivalent) and lock cursor fields.
- Treat field selection as a runtime contract. Discovery exposes the full schema, but reads must emit only explicitly selected fields plus required identity, cursor, deletion, and framework fields. Push the projection into the source API when supported, and filter both dlt hints and emitted rows so deselected null columns cannot reappear during normalize.
- Never treat an empty explicit selection as "all fields." `None`/unset means no explicit projection; an empty set means retain only required operational fields.
- Ensure capabilities declared in connector metadata match implemented methods.
- Apply cancellation checks in every long-running loop, retry loop, and statement execution path.
- Treat `MetadataSkipReason` as a backend/frontend wizard contract. Do not add or repurpose enum values from a connector without coordinated frontend classification, copy, generated type, selection, validation, and save-behavior updates.
- Never default `trustServerCertificate=true` for production-facing connectors. Use `false` by default and require explicit opt-in for insecure/dev TLS behavior.
- Source-only connectors MUST implement stub methods for `mapToTargetObject`, `stage`, and `load` that throw `UnsupportedOperationException` or `ConnectorException` with `UNSUPPORTED_OPERATION`. The interface requires them even if the connector is source-only.
- For destinations, implement required destination methods and identifier formatter methods expected by mapping/pipeline.
- JDBC source and hybrid connectors MUST override `convertToCanonicalValue()` to handle both
  database-specific Java classes and canonical-type semantics. In particular, native JSON returned
  as text must remain a JSON object/array/scalar rather than becoming a quoted JSON string.
  Exercise the actual driver value shapes for JSON, binary, temporal, array, and struct types.
- Keep integration tests meaningful: incremental windows, cursor advancement, and schema-to-record field coverage.
- Every source connector must include a sparse field-selection regression covering initial and incremental reads. Assert that a selected field is present, a known deselected field is absent, and required identity/cursor/system fields remain usable. Python/dlt connectors must exercise `ReadHarness(selected_fields_factory=...)` and verify source/API projection separately with a fake client.
- Every structured destination must prove the full system-field contract using production writer
  output: `_supa_synced`, `_supa_deleted`, `_supa_index`, `_supa_id`, and `_supa_job_id` appear
  exactly once, have destination-appropriate physical types, and retain the shared SDK's exact
  values. Never recompute or redefine these fields in connector-specific code.
- Warehouse `MERGE` must deterministically deduplicate a same-batch `_supa_id`: order by selected
  business cursor fields descending, then `_supa_synced` descending, then `_supa_index`
  descending. With no cursor, fall back to `_supa_synced`, then `_supa_index`. Prove SQL ordering
  plus a live merge path.
- A warehouse all-types round trip means production writer output is staged, loaded, read back,
  and compared by value for every canonical type, nulls, maximum supported decimal envelopes,
  temporal precision, JSON semantics, and binary bytes. Separately document fresh-discovery
  widenings or collapses; do not claim canonical identity when only values are lossless.
- For externally staged warehouses, decide and document who owns the staging bucket/stage before
  implementation. Prefer a customer-provided location when staged files contain customer data;
  preserve customer IAM/encryption controls, use a job-scoped prefix, delete staged objects after
  terminal success or failure, configure a short lifecycle backstop for interrupted cleanup, and
  bound live-test spend with provider-native query/job limits and cleanup.
- For connector docs and marketing, existing clean docs are the template; connector code is only the validation source.
- For connector docs and marketing, do not put object lists, sync modes, cursor fields, or internal columns in the opening paragraph.
- For connector docs and marketing, treat protocol details, raw internal identifiers, endpoint paths, API-version/query-shape discussion, and versioned product wording like `v1 connector` as red flags unless the user truly needs them.
- For connector docs and marketing, use the standard rate-limit pattern from `references/CONNECTOR_DOCS_MARKETING.md` instead of baking source-specific limit numbers into the page.
- For connector marketing pages, remember they are template-driven `ConnectorMarketing` entries, not freeform docs. Keep copy shaped to the existing template fields.
- For connector marketing pages, `setupSteps.detail` and `faq.answer` are plain-text surfaces. Do not rely on markdown formatting or long copied vendor workflows there.
- For protected scopes, approval-only permissions, or other vendor-controlled access steps in docs/marketing, explain the requirement briefly, explain why it matters, and point to official docs instead of restating the mutable vendor workflow.
- For source-doc configuration sections, use `FieldLabel ... required` for required fields, use `Options:` for enum values, and group advanced settings only when it improves scanning.

## Completion Criteria

- Phase 0 completed (mandatory references read).
- Phase 0 gate output shown before first code edit (and repeated after compaction).
- Correct phase track completed for the connector mode.
- Verification script passes all applicable final-state checks (Python/dlt field-projection gates, or Java checks `1-15`, `25-27`, and source/destination-specific checks; Java destinations also run `16-24` plus maturity and packaging gates).
- Verification script re-run after integration tests are written (not just at end of build).
- Field selection is behaviorally proven for initial and incremental reads; accepting a `selected_fields` argument without using it does not satisfy this criterion.
- Cutoff-state IT proves both empty-initial suppression and empty-incremental advancement.
- Warehouse IT uses a dedicated all-types test and proves exact values, system fields, and merge
  winner ordering; a generic `CanonicalType` reference is not evidence.
- Warehouse IT behaviorally asserts callback counts and reads error artifacts for forced bad rows
  in moderate and strict modes; collecting callback objects or configuring `errorPath` is not
  evidence.
- Warehouse IT proves additive and type-change schema evolution, advertised hard deletes, and
  user-owned physical-design preservation after destructive load paths.
- External-stage IT proves normal and failure-path cleanup (or bounded retained diagnostics);
  cleanup code and lifecycle configuration without execution-path assertions are not evidence.
- Anti-pattern checks reviewed before final handoff.
- If the task includes connector docs or marketing, `references/CONNECTOR_DOCS_MARKETING.md` was followed and a red-flag sweep was completed before final handoff.
- If the task includes connector marketing pages, a template-surface pass was completed to confirm the copy fits the actual renderer and data shape.
- Final handoff includes what was implemented, gate outputs, and any remaining risks/assumptions.
