## Table of Contents

- [What this does](#what-this-does)
- [Quick Start (Claude Code)](#quick-start-claude-code)
- [Other Agents](#other-agents)
- [How it works](#how-it-works)
- [Usage](#usage)
- [Verification Script](#verification-script)
- [Skill Structure](#skill-structure)
- [Reference Connectors](#reference-connectors)
- [Portability](#portability)
- [FAQ](#faq)
- [License](#license)

# Supaflow Connector Skills

AI-agent skills for building [Supaflow](https://www.supa-flow.io) data connectors. Guides an agent through
an 8-phase workflow with gate checks, anti-pattern enforcement, and a verification script that validates
the result.

Works with **Claude Code**, **OpenAI Codex**, and any agent that supports skill/prompt files.

## What this does

**Does**
- Walk an AI coding agent through building a complete Supaflow connector (source, direct database destination, warehouse/file destination, or activation target)
- Enforce phased gates -- the agent cannot skip ahead until the current phase passes verification
- Catch 20+ known anti-patterns before they reach production (e.g., calling `processor.close()`, missing `originalDataType`, using raw `maxCursorSeen` without a compatible boundary strategy)
- Run automated verification across all applicable checks (`1-27`, plus `3.5`)

**Does not**
- Require any specific IDE or editor
- Modify your Supaflow platform code directly -- the agent does that, guided by the skill
- Replace integration testing -- you still need live API credentials to run IT tests

## Quick Start (Claude Code)

```bash
# Clone the repo
git clone https://github.com/supaflow-labs/supaflow-connector-dev-skills.git

# Symlink the skill into your Claude Code skills directory
mkdir -p ~/.claude/skills
ln -s "$(pwd)/supaflow-connector-dev-skills/skills/build-supaflow-connector" \
      ~/.claude/skills/build-supaflow-connector
```

Start a new Claude Code session. The skill is now available as `/build-supaflow-connector`.

The skill will ask you to provide the following inputs. Here's how to fill them in:

| Input | What to provide | Examples |
|-------|----------------|----------|
| `platform_root` | Absolute path to your `supaflow-platform` clone | `/home/user/supaflow-platform` |
| `connector_name` | Short lowercase name used as the module suffix. Becomes `supaflow-connector-<name>` | `stripe`, `sqlserver`, `bigquery` |
| `connector_mode` | What the connector does. Pick one | `source`, `destination-database`, `destination-warehouse`, `destination-activation`, `hybrid` |
| `auth_type` | How the source/destination authenticates. Use `custom` if it doesn't fit a standard pattern | `API key`, `OAuth client credentials`, `OAuth auth code`, `custom` |
| `api_surface` | Describe the API: what objects exist, how pagination works, rate limits, and which fields support incremental sync. For JDBC connectors, mention the driver and reference the closest existing connector | `JDBC-based (like postgres); objects=tables,views; cursor_fields=datetime columns` |
| `test_credentials` | Environment variable names needed for integration tests | `STRIPE_API_KEY` or `SQLSERVER_HOST, SQLSERVER_PORT, SQLSERVER_USERNAME, SQLSERVER_PASSWORD` |

**Example -- REST API source:**
```
/build-supaflow-connector

platform_root: /home/user/supaflow-platform
connector_name: stripe
connector_mode: source
auth_type: API key
api_surface: objects=customers,invoices,charges; pagination=cursor; rate_limit=100 req/sec; cursor_fields=created
test_credentials: STRIPE_API_KEY
```

**Example -- JDBC source:**
```
/build-supaflow-connector

platform_root: /home/user/supaflow-platform
connector_name: sqlserver
connector_mode: source
auth_type: custom
api_surface: JDBC-based (like postgres connector); objects=tables,views; pagination=JDBC ResultSet; cursor_fields=datetime/timestamp columns; uses mssql-jdbc driver; supports SQL Server and Azure SQL Database
test_credentials: SQLSERVER_HOST, SQLSERVER_PORT, SQLSERVER_DATABASE, SQLSERVER_USERNAME, SQLSERVER_PASSWORD
```

The symlink points to the live repo, so `git pull` picks up updates immediately.

### Other Agents

Each agent platform has its own installation steps:

- **OpenAI Codex**: See [`skills/build-supaflow-connector/references/README.md`](skills/build-supaflow-connector/references/README.md) for Codex-specific install and trigger instructions.
- **Other agents**: Point the agent at `skills/build-supaflow-connector/SKILL.md` as its system prompt, and ensure it has access to the `references/` and `scripts/` subdirectories. Trigger mechanics are agent-specific.

**Note on SKILL.md frontmatter:** The frontmatter includes agent-specific UI keys (`argument-hint`, `context`). Do not add `disable-model-invocation`; this skill should be available to model-triggered agents as well as slash-command users.
If an agent platform cannot invoke the skill through its skill tool, fall back to reading `skills/build-supaflow-connector/SKILL.md` directly and follow the referenced docs/scripts.

## How it works

The skill guides an agent through a phased build process. Each phase has a defined scope,
prerequisite reading, and a gate check that must pass before proceeding.

### Phase Tracks

| Connector Mode | Phases |
|---------------|--------|
| Source | 1 &rarr; 2 &rarr; 3 &rarr; 4 &rarr; 5 &rarr; 6 |
| Direct Database Destination | 1 &rarr; 2 &rarr; 3 &rarr; 4 &rarr; 7 + destination tests |
| Warehouse/File Destination | 1 &rarr; 2 &rarr; 3 &rarr; 4 &rarr; 7 + destination tests |
| Activation Destination | 1 &rarr; 2 &rarr; 3 &rarr; 4 &rarr; 8 + destination tests |
| Hybrid | Source track plus the applicable destination track |

### Phases

| Phase | Purpose | Gate Checks |
|-------|---------|-------------|
| 1 | Project structure, pom.xml, shell class | 9, 14, 25 |
| 2 | Connector identity, properties, capabilities | 4, 5, 6, 11, 26 |
| 3 | Connection, auth, token management | 7, 10 |
| 4 | Schema discovery, ObjectMetadata, FieldMetadata | 3.5, 12, 13 |
| 5 | Read operations, SyncState, CutoffTime pattern | 1, 2, 3, 8 |
| 6 | Integration testing | 15 |
| 7 | Structured destinations: direct database, warehouse/file stage(), load() | 16-24, 27 |
| 8 | Activation targets: activation mappings | 16-24 |

### Hard Guardrails

These rules are enforced at every phase:

- Never call `processor.close()` -- the executor manages the lifecycle
- Always set `originalDataType` on every `FieldMetadata`
- Always implement incremental sync with `CutoffTimeSyncUtils`
- Always run `identifyCursorFields()` and lock cursor fields
- Declared capabilities must match implemented methods
- Cancellation checks in every long-running loop
- For destinations: apply `NamespaceRules`, use `request.getSyncTime()`, don't add tracking columns manually

## Usage

### Required Inputs

| Input | Description | Example |
|-------|-------------|---------|
| `platform_root` | Absolute path to Supaflow platform repo | `/home/user/supaflow-platform` |
| `connector_name` | Module suffix | `stripe` |
| `connector_mode` | Connector type | `source`, `destination-database`, `destination-warehouse`, `destination-activation`, `hybrid` |
| `auth_type` | Authentication method | `API key`, `OAuth client credentials`, `OAuth auth code`, `custom` |
| `api_surface` | API details | `objects=customers,invoices; pagination=cursor; cursor_fields=created` |
| `test_credentials` | Required env vars | `STRIPE_API_KEY` |

### Example: Warehouse Destination

```
platform_root: /home/user/supaflow-platform
connector_name: bigquery
connector_mode: destination-warehouse
auth_type: OAuth client credentials
api_surface: load via staging (GCS); DDL for table creation; MERGE for upserts
test_credentials: GOOGLE_APPLICATION_CREDENTIALS
```

## Verification Script

The bundled verification script runs all applicable automated checks against a connector module: source/shared checks `1-15`, setup/dependency/cancellation checks `25-27`, schema compliance check `3.5`, and destination checks `16-24` when destination capabilities are present.

```bash
# Run all checks
bash scripts/verify_connector.sh <connector-name> <platform-root>

# Or export the platform root once
export SUPAFLOW_PLATFORM_ROOT=/path/to/supaflow-platform
bash scripts/verify_connector.sh <connector-name>
```

### Source Checks (1-15)

| Check | What It Verifies |
|-------|-----------------|
| 1 | RecordProcessor lifecycle (no manual close) |
| 2 | DatasourceInitResponse usage |
| 3 | Required methods implementation |
| 3.5 | ObjectMetadata and FieldMetadata requirements |
| 4 | Version management |
| 5 | Connector capabilities declared |
| 6 | Property annotations |
| 7 | Connection management |
| 8 | Incremental sync implementation |
| 9 | Build configuration (pom.xml, shade plugin) |
| 10 | OAuth implementation |
| 11 | Naming conventions |
| 12 | PK and cursor field identification |
| 13 | Cursor field setting invoked |
| 14 | Build artifacts not committed |
| 15 | Integration tests exist |
| 25 | Parent POM module registration |
| 26 | Dependency version management |
| 27 | Cancellation support |

### Destination Checks (16-24)

Auto-detected when connector has `REPLICATION_DESTINATION` or `REVERSE_ETL_DESTINATION` capability.

| Check | What It Verifies |
|-------|-----------------|
| 16 | Destination capabilities configuration |
| 17 | mapToTargetObject() implementation |
| 18 | load() implementation |
| 19 | stage() implementation |
| 20 | Direct CSV/COPY load, staged COPY INTO, or activation_target |
| 21 | MERGE/upsert or activation_target_field |
| 22 | LoadMode handling or merge_keys |
| 23 | DDL/schema evolution or error/success processors |
| 24 | Destination integration tests |

## Skill Structure

```
supaflow-connector-dev-skills/
├── skills/
│   └── build-supaflow-connector/
│       ├── SKILL.md                          # Skill entry point
│       ├── agents/
│       │   └── openai.yaml                   # OpenAI Codex agent config
│       ├── scripts/
│       │   └── verify_connector.sh           # Gate verification script
│       └── references/
│           ├── README.md                     # Skill quick reference
│           ├── ANTI_PATTERNS.md              # 20+ anti-patterns with fixes
│           ├── PORTABILITY.md                # Cross-environment usage
│           ├── PHASE_1_PROJECT_SETUP.md      # Directory structure, pom.xml
│           ├── PHASE_2_CONNECTOR_IDENTITY.md # Properties, capabilities
│           ├── PHASE_3_CONNECTION_AUTH.md     # Auth, token management
│           ├── PHASE_4_SCHEMA_DISCOVERY.md   # ObjectMetadata, FieldMetadata
│           ├── PHASE_5_READ_OPERATIONS.md    # read(), SyncState, CutoffTime
│           ├── PHASE_6_INTEGRATION_TESTING.md # IT tests, verification
│           ├── PHASE_7_WRITE_OPERATIONS.md   # Warehouse: stage(), load()
│           └── PHASE_8_ACTIVATION_TARGETS.md # API destinations
├── LICENSE
└── README.md
```

## Reference Connectors

The skill references existing Supaflow connectors as implementation examples.
These live in the `supaflow-platform` repo, not in this skill repo.

| Connector | Pattern | Reference For |
|-----------|---------|---------------|
| `supaflow-connector-airtable` | OAuth2 + PAT | Dynamic schema, cursor tracking |
| `supaflow-connector-hubspot` | OAuth2 Auth Code | V2 architecture, YAML config |
| `supaflow-connector-oracle-tm` | Basic Auth | Time-based incremental sync |
| `supaflow-connector-salesforce` | OAuth2 + SOAP | Bulk API, activation destination |
| `supaflow-connector-postgres` | JDBC | BaseJdbcConnector pattern |
| `supaflow-connector-snowflake` | JDBC + Stage | Warehouse destination (Phase 7) |
| `supaflow-connector-salesforce-marketing-cloud` | OAuth2 | SFMC patterns, REST + SOAP |

## Portability

### Minimum Platform Requirements

The `platform_root` directory must contain:
- `pom.xml` (root Maven POM)
- `connectors/` directory
- `supaflow-connector-sdk/` and `supaflow-core/` modules

### Customizing Reference Connectors

If your platform fork uses different reference connectors, set these variables
before invoking the skill:

- `REFERENCE_SOURCE_CONNECTOR` (default: `hubspot`, `oracle-tm`)
- `REFERENCE_DESTINATION_CONNECTOR` (default: `snowflake`)
- `REFERENCE_ACTIVATION_CONNECTOR` (default: `salesforce`)

## FAQ

**Do I need the full Supaflow platform to use this?**
Yes. The skill generates code that compiles against `supaflow-connector-sdk` and `supaflow-core`.
You need a working `supaflow-platform` clone with `mvn clean install` passing.

**Can I use this for non-Supaflow connectors?**
The skill is specific to the Supaflow connector interface (`SupaflowConnector`). The anti-patterns
and architectural guidance may still be useful for similar connector frameworks.

**What if the verification script fails on a check that doesn't apply?**
Some checks auto-detect applicability (e.g., destination checks only run when
destination capabilities are declared). If a check is genuinely not applicable,
document the skip reason in your handoff notes.

**How do I update the skill after cloning?**
```bash
cd supaflow-connector-dev-skills
git pull
```
The symlink (Claude Code) points to the live repo, so updates are immediate.
If you used `cp` (Codex), re-copy to pick up changes.

## License

MIT License. See `LICENSE`.
