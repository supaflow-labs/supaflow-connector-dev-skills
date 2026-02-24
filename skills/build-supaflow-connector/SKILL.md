---
name: build-supaflow-connector
description: Build or review Supaflow connectors using a phased workflow for source connectors, warehouse destinations, and activation targets. Use this skill when implementing new connectors, debugging connector behavior, or validating connector quality in a Supaflow platform repository with gate checks and anti-pattern enforcement.
---

# Build Supaflow Connector

Build connectors phase-by-phase, enforce verification gates before moving forward, and apply hard guardrails from anti-pattern documentation.

## Collect Inputs First

- `platform_root`: absolute path to a Supaflow platform repo clone containing `pom.xml` and `connectors/`
- `connector_name`: directory/module suffix (for example, `airtable`)
- `connector_mode`: `source`, `destination-warehouse`, `destination-activation`, or `hybrid`
- `auth_type`: API key, OAuth client credentials, OAuth auth code, or custom
- `api_surface`: object endpoints, pagination model, rate limits, and date/cursor fields
- `test_credentials`: required env vars and sandbox/test account scope

## Load References by Need

- Always read first:
`references/ANTI_PATTERNS.md`
`references/PORTABILITY.md`
`references/README.md`
- Then load phase docs only for the current phase:
`references/PHASE_1_PROJECT_SETUP.md`
`references/PHASE_2_CONNECTOR_IDENTITY.md`
`references/PHASE_3_CONNECTION_AUTH.md`
`references/PHASE_4_SCHEMA_DISCOVERY.md`
`references/PHASE_5_READ_OPERATIONS.md`
`references/PHASE_6_INTEGRATION_TESTING.md`
`references/PHASE_7_WRITE_OPERATIONS.md`
`references/PHASE_8_ACTIVATION_TARGETS.md`

## Choose Track

- `source`: complete phases `1 -> 6`
- `destination-warehouse`: complete phases `1 -> 4`, then `7`, then destination tests/checks
- `destination-activation`: complete phases `1 -> 4`, then `8`, then destination tests/checks
- `hybrid`: execute both destination tracks (`7` and `8`) only if the connector truly supports both patterns

## Phase Protocol (Do Not Skip)

1. Read the phase doc prerequisites and required core classes.
2. Implement only the current phase scope.
3. Run phase gate checks and show command output.
4. Fix all failures.
5. Proceed to the next phase only after the current phase is clean.

## Required Commands

Use the bundled verification script from this skill package.

```bash
PLATFORM_ROOT="<abs-path-to-platform-repo>"
SKILL_ROOT="<abs-path-to-this-skill-folder>"

# Build connector module quickly during iteration
cd "$PLATFORM_ROOT"
mvn -pl connectors/supaflow-connector-<connector_name> -DskipTests clean install

# Gate verification (must pass before moving phases)
bash "$SKILL_ROOT/scripts/verify_connector.sh" <connector_name> "$PLATFORM_ROOT"
```

Use full-repo build when dependency graph changes:

```bash
mvn clean install
```

## Hard Guardrails

- Never call `processor.close()` manually in `read()`.
- Always set `originalDataType` on every `FieldMetadata`.
- Always implement incremental sync with `CutoffTimeSyncUtils` patterns.
- Never treat cursor position as a single scalar; respect incremental field structures.
- Always run cursor identification (`identifyCursorFields()` or equivalent) and lock cursor fields.
- Ensure capabilities declared in connector metadata match implemented methods.
- Apply cancellation checks in every long-running loop, retry loop, and statement execution path.
- For destinations, implement required destination methods and identifier formatter methods expected by mapping/pipeline.
- Keep integration tests meaningful: incremental windows, cursor advancement, and schema-to-record field coverage.

## Completion Criteria

- Correct phase track completed for the connector mode.
- Verification script passes all applicable checks (`1-15` for source, plus `16-24` for destinations).
- Anti-pattern checks reviewed before final handoff.
- Final handoff includes what was implemented, gate outputs, and any remaining risks/assumptions.
