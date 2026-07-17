---
name: build-supaflow-connector
description: Build or review Supaflow connectors using a phased workflow for source connectors, structured destinations, and activation targets. Use this skill when implementing new connectors, debugging connector behavior, or validating connector quality in a Supaflow platform repository with gate checks and anti-pattern enforcement.
argument-hint: <connector-name> <source|destination-database|destination-warehouse|destination-activation|hybrid>
context: fork
---

# Build Supaflow Connector

Build connectors phase-by-phase, enforce verification gates before moving forward, and apply hard guardrails from anti-pattern documentation.

## Collect Inputs First

- `platform_root`: absolute path to a Supaflow platform repo clone containing `pom.xml` and `connectors/`
- `connector_name`: directory/module suffix (for example, `airtable`)
- `connector_mode`: `source`, `destination-database`, `destination-warehouse`, `destination-activation`, or `hybrid`
- `connector_base`: `jdbc` if JDBC-based (extends BaseJdbcConnector), otherwise `api` (default)
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

Do not modify connector files until the Phase 0 gate output is shown.

If your session context was compacted or you lost prior instructions, re-read this SKILL.md and repeat Phase 0 before continuing.

## Detect Connector Base

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

## Load Phase Docs by Need

Load only the current phase doc. For JDBC connectors, load `references/JDBC_CONNECTOR_GUIDE.md` instead of phases 3-5.

- `references/PHASE_1_PROJECT_SETUP.md`
- `references/PHASE_2_CONNECTOR_IDENTITY.md`
- `references/PHASE_3_CONNECTION_AUTH.md` (API connectors only)
- `references/PHASE_4_SCHEMA_DISCOVERY.md` (API connectors only)
- `references/PHASE_5_READ_OPERATIONS.md` (API connectors only)
- `references/JDBC_CONNECTOR_GUIDE.md` (JDBC connectors: replaces phases 3-5)
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

Use full-repo build when dependency graph changes:

```bash
mvn clean install
```

## Hard Guardrails

- Never call `processor.close()` manually in `read()`.
- Always set `originalDataType` on every `FieldMetadata`.
- Always implement incremental sync with `CutoffTimeSyncUtils` patterns (API connectors) or base class cursor support (JDBC connectors).
- Never treat cursor position as a single scalar; respect incremental field structures.
- Always run cursor identification (`identifyCursorFields()` or equivalent) and lock cursor fields.
- Ensure capabilities declared in connector metadata match implemented methods.
- Apply cancellation checks in every long-running loop, retry loop, and statement execution path.
- Treat `MetadataSkipReason` as a backend/frontend wizard contract. Do not add or repurpose enum values from a connector without coordinated frontend classification, copy, generated type, selection, validation, and save-behavior updates.
- Never default `trustServerCertificate=true` for production-facing connectors. Use `false` by default and require explicit opt-in for insecure/dev TLS behavior.
- Source-only connectors MUST implement stub methods for `mapToTargetObject`, `stage`, and `load` that throw `UnsupportedOperationException` or `ConnectorException` with `UNSUPPORTED_OPERATION`. The interface requires them even if the connector is source-only.
- For destinations, implement required destination methods and identifier formatter methods expected by mapping/pipeline.
- JDBC connectors MUST override `convertToCanonicalValue()` to handle database-specific Java types returned by the JDBC driver. Without this, proprietary types (e.g., `microsoft.sql.DateTimeOffset`, `org.postgresql.util.PGobject`) cause ClassCastException at runtime.
- Keep integration tests meaningful: incremental windows, cursor advancement, and schema-to-record field coverage.
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
- Verification script passes all applicable final-state checks (`1-15`, `25-27`, and source/destination-specific checks; destinations also run `16-24`).
- Verification script re-run after integration tests are written (not just at end of build).
- Anti-pattern checks reviewed before final handoff.
- If the task includes connector docs or marketing, `references/CONNECTOR_DOCS_MARKETING.md` was followed and a red-flag sweep was completed before final handoff.
- If the task includes connector marketing pages, a template-surface pass was completed to confirm the copy fits the actual renderer and data shape.
- Final handoff includes what was implemented, gate outputs, and any remaining risks/assumptions.
