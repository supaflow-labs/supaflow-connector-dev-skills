# Portability Guide

Use this skill in any environment by parameterizing paths and references.

## Required Inputs

- `PLATFORM_ROOT`: absolute path to the Supaflow platform repo you are modifying.
- `CONNECTOR_NAME`: connector suffix (for example, `hubspot`).
- `SKILL_ROOT`: absolute path to this skill folder.

## Minimum Platform Layout

`PLATFORM_ROOT` must include:

- `pom.xml`
- `connectors/`
- `supaflow-connector-sdk/` and `supaflow-core/` modules (or equivalent paths discoverable by `find`)

## Verification (Bundled Script)

Use the skill-local verifier instead of relying on external repo docs:

```bash
bash "$SKILL_ROOT/scripts/verify_connector.sh" "$CONNECTOR_NAME" "$PLATFORM_ROOT"
```

You can also export once:

```bash
export SUPAFLOW_PLATFORM_ROOT="$PLATFORM_ROOT"
bash "$SKILL_ROOT/scripts/verify_connector.sh" "$CONNECTOR_NAME"
```

## Reference Connector Selection

Phase docs use configurable reference variables:

- `REFERENCE_SOURCE_CONNECTOR` (default examples: `hubspot`, `oracle-tm`)
- `REFERENCE_DESTINATION_CONNECTOR` (default example: `snowflake`)
- `REFERENCE_ACTIVATION_CONNECTOR` (default example: `salesforce`)

Set these to connectors that exist in your platform repo.

## If Reference Connectors Are Missing

- Continue with phase-specific examples in the docs.
- Enforce anti-pattern checks from `ANTI_PATTERNS.md`.
- Validate behavior with integration tests before advancing phases.
