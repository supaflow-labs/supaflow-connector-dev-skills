# Connector Development Skills

This directory contains phased skill documents for building Supaflow connectors.

## Codex Quick Start (Codex-Specific)

This section is specific to Codex local skills. Do not assume these install/trigger steps apply to other coding agents.

### 1) Install the skill locally in Codex

```bash
mkdir -p ~/.codex/skills
SKILL_SRC="/absolute/path/to/build-supaflow-connector"
rsync -a "$SKILL_SRC"/ ~/.codex/skills/build-supaflow-connector/
```

Example with this repo:

```bash
rsync -a /path/to/supaflow-connector-skills/skills/build-supaflow-connector/ ~/.codex/skills/build-supaflow-connector/
```

### 2) Start a new Codex session

Codex loads installed skills at session start. Open a new chat/session after copying the skill.

### 3) Trigger the skill in prompt

Use either syntax:

- `$build-supaflow-connector`
- `Use the build-supaflow-connector skill`

### 4) Real prompt example (copy/paste)

```text
Use $build-supaflow-connector.

platform_root: /absolute/path/to/supaflow-platform
connector_name: stripe
connector_mode: source
auth_type: API key
api_surface: objects=customers,invoices,charges; pagination=cursor; rate_limit=100 req/sec; cursor_fields=created
test_credentials: STRIPE_API_KEY
```

## Skill Documents

| Phase | File | Purpose | Gate Checks |
|-------|------|---------|-------------|
| 1 | `PHASE_1_PROJECT_SETUP.md` | Project structure, pom.xml, shell class | 9, 14 |
| 2 | `PHASE_2_CONNECTOR_IDENTITY.md` | getType, getName, properties, capabilities | 5, 6, 11 |
| 3 | `PHASE_3_CONNECTION_AUTH.md` | setRuntimeContext, init, OAuth | 7, 10 |
| 4 | `PHASE_4_SCHEMA_DISCOVERY.md` | schema(), ObjectMetadata, FieldMetadata | 4, 12, 13 |
| 5 | `PHASE_5_READ_OPERATIONS.md` | read(), SyncStateRequest, RecordProcessor | 1, 2, 3, 8 |
| 6 | `PHASE_6_INTEGRATION_TESTING.md` | IT tests, verification | 15 |
| 7 | `PHASE_7_WRITE_OPERATIONS.md` | Warehouse destinations: stage(), load() | 3, 12 |
| 8 | `PHASE_8_ACTIVATION_TARGETS.md` | API destinations: activation mappings | 3, 12 |
| - | `ANTI_PATTERNS.md` | Common mistakes to avoid | All |
| JDBC | `JDBC_CONNECTOR_GUIDE.md` | **Replaces phases 3-5 for JDBC connectors** | JDBC-specific |

**JDBC Connectors**: If the connector extends `BaseJdbcConnector` (uses a JDBC driver), follow `JDBC_CONNECTOR_GUIDE.md` instead of phases 3-5. The base class handles read(), schema(), cursor fields, and cancellation. You only implement `validateAndSetConnectorProperties()`, `mapTypeByName()`, `convertToCanonicalValue()`, and source-only stubs.

**Destination Phases**:
- **Phase 7**: For warehouse destinations (Snowflake, BigQuery) - creates tables/schemas via DDL
- **Phase 8**: For API destinations (Salesforce, HubSpot) - maps to existing objects, no DDL

## How to Use These Skills

### Cancellation Is Mandatory (Do This In Every Connector)

- Always capture the cancellation supplier from `ConnectorRuntimeContext` and pass it into clients/helpers.
- Check cancellation inside every long-running loop (pagination, per-record, retries/backoff, result iteration).
- JDBC connectors must register/clear statements for cancellation (`registerCurrentStatement` / `clearCurrentStatement`).
- Never swallow or retry `ConnectorException.ErrorType.CANCELLED`.

### For Agents Building Connectors

1. **Read phases sequentially** - Don't skip ahead
2. **Complete gate verification** before proceeding to next phase
3. **Read prerequisite classes** listed at the start of each phase
4. **Check ANTI_PATTERNS.md** before and after implementation
5. **Run verification script** after each phase
6. **Apply manual quality guardrails** listed below before handing off

### Agent Instructions Template

```
Build a {ConnectorName} connector following the phased skill approach:

1. Read `references/ANTI_PATTERNS.md` first
2. Complete each phase in order:
   - Phase 1: Project Setup → Run gate verification
   - Phase 2: Identity & Properties → Run gate verification
   - Phase 3: Connection & Auth → Run gate verification
   - Phase 4: Schema Discovery → Run gate verification
   - Phase 5: Read Operations → Run gate verification
   - Phase 6: Integration Testing → Run gate verification
   - Phase 7: Write Operations (warehouse destinations like Snowflake)
   - Phase 8: Activation Targets (API destinations like Salesforce)

3. For each phase:
   - Read the ESSENTIAL READING section first
   - Read the actual core class files listed
   - Implement following the examples
   - Run gate verification before proceeding

4. Build a connector-specific implementation prompt from your target API and connector mode (source, destination-warehouse, destination-activation).

5. Final verification: bash <skill-root>/scripts/verify_connector.sh {name} {platform-root}
   All checks must pass (15 source + 9 destination if applicable).

DO NOT proceed to next phase until current phase passes.
Show gate verification output before moving on.
```

## Verification Script

```bash
# Run verification on a connector (standalone skill package)
bash ./scripts/verify_connector.sh {connector-name} {platform-root}

# Optional: export once instead of passing root each time
export SUPAFLOW_PLATFORM_ROOT={platform-root}
bash ./scripts/verify_connector.sh {connector-name}

# Expected: All checks pass
# - Source connectors: 15 checks
# - Destination connectors: +9 additional checks (16-24)
```

## Directory Structure

```
build-supaflow-connector/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── scripts/
│   └── verify_connector.sh
└── references/
    ├── README.md
    ├── PORTABILITY.md
    ├── PHASE_1_PROJECT_SETUP.md
    ├── PHASE_2_CONNECTOR_IDENTITY.md
    ├── PHASE_3_CONNECTION_AUTH.md
    ├── PHASE_4_SCHEMA_DISCOVERY.md
    ├── PHASE_5_READ_OPERATIONS.md
    ├── PHASE_6_INTEGRATION_TESTING.md
    ├── PHASE_7_WRITE_OPERATIONS.md
    ├── PHASE_8_ACTIVATION_TARGETS.md
    └── ANTI_PATTERNS.md
```

## Reference Connectors

| Connector | Pattern | Reference For |
|-----------|---------|---------------|
| `supaflow-connector-airtable` | OAuth2 + PAT | Dynamic schema, cursor tracking |
| `supaflow-connector-hubspot` | OAuth2 Auth Code | V2 architecture, YAML config |
| `supaflow-connector-oracle-tm` | Basic Auth | Time-based incremental sync |
| `supaflow-connector-salesforce` | OAuth2 + SOAP | Utility classes, bulk API |
| `supaflow-connector-postgres` | JDBC | **JDBC source+destination reference** (BaseJdbcConnector, convertToCanonicalValue, mapTypeByName) |
| `supaflow-connector-generic-jdbc` | JDBC | **JDBC source-only reference** (minimal BaseJdbcConnector subclass) |
| `supaflow-connector-snowflake` | JDBC + Stage | **Warehouse destination (Phase 7)** |
| `supaflow-connector-salesforce` | OAuth2 + SOAP | **Activation destination (Phase 8)** |
| `supaflow-connector-salesforce-marketing-cloud` | OAuth2 | SFMC patterns, REST + SOAP |

## Gate Verification Mapping

### Source Connector Checks (1-15)

| Check | What It Verifies | Phase |
|-------|-----------------|-------|
| 1 | RecordProcessor lifecycle | 5 |
| 2 | DatasourceInitResponse usage | 3, 5 |
| 3 | Required methods implementation | 5 |
| 4 | FieldMetadata requirements | 4 |
| 5 | Connector capabilities | 2 |
| 6 | Property annotations | 2 |
| 7 | Connection management | 3 |
| 8 | Incremental sync implementation | 5 |
| 9 | Build configuration | 1 |
| 10 | OAuth implementation | 3 |
| 11 | Naming conventions | 2 |
| 12 | PK and cursor field identification | 4 |
| 13 | Cursor field setting invoked | 4 |
| 14 | Build artifacts not committed | 1 |
| 15 | Integration tests exist | 6 |

### Destination Connector Checks (16-24)

Auto-detected when connector has `REPLICATION_DESTINATION` or `REVERSE_ETL_DESTINATION` capability.

| Check | What It Verifies | Phase |
|-------|-----------------|-------|
| 16 | Destination capabilities configuration | 7, 8 |
| 17 | mapToTargetObject() implementation | 7, 8 |
| 18 | load() implementation | 7, 8 |
| 19 | stage() implementation | 7, 8 |
| 20 | Staging/COPY INTO (warehouse) OR activation_target (activation) | 7, 8 |
| 21 | MERGE (warehouse) OR activation_target_field (activation) | 7, 8 |
| 22 | LoadMode handling (warehouse) OR merge_keys (activation) | 7, 8 |
| 23 | DDL generation (warehouse) OR error/success processors (activation) | 7, 8 |
| 24 | Destination integration tests | 7, 8 |

**Note**: Destination connectors must also implement identifier formatting methods from Phase 4 (`getIdentifierFormatter`, `getIdentifierQuoteString`, `getIdentifierSeparator`, `getFullyQualifiedSchemaName`, `getFullyQualifiedTableName`). The pipeline uses them during mapping even for file-based destinations.

## Manual Quality Guardrails (Required)

These are mandatory in addition to `verify_connector.sh`:

1. **API contract freshness**
   - All examples use `read(ReadRequest)` (not legacy multi-arg signatures).
   - `SyncStateRequest.getCursorPosition()` is treated as `List<IncrementalField>`, never as a scalar string.

2. **Incremental-window correctness**
   - Read examples use `CutoffTimeSyncUtils` for deterministic lower/upper bounds.
   - No index-based cursor extraction (`getCursorPosition().get(0)`) in generic templates.

3. **Schema inference consistency**
   - Sample-based schema discovery documents the SDK path: `RecordSupplier -> SchemaGenerator -> SchemaInferenceResult`.
   - If connector-specific heuristics exist, they are documented as post-inference reconciliation, not ad-hoc type guessing everywhere.

4. **Integration test oracle quality**
   - Incremental IT validates lower/upper bounds and zero-record cursor advancement.
   - Record mapping IT validates schema-to-record field coverage, not just non-empty reads.
