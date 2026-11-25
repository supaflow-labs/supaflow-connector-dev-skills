# Standalone Python Source Connectors

Use this workflow for a connector in its own Python project, with the Supaflow
CLI owning scaffolding, locks, tests and builds. Both Claude Code
(`/build-supaflow-connector`) and Codex (`$build-supaflow-connector`) use this same
guide. Do not apply the platform phases, Maven commands, Java stub requirements,
or `verify_connector.sh` to a standalone project.

## Establish Inputs and Scope

Use supplied values and inspect an existing project's `pyproject.toml` before
asking for missing information:

- `workflow`: optional selection hint, `standalone-cli` for this guide.
- `project_root`: new directory to create, or the existing standalone project.
- `connector_name`: canonical local name, such as `MVP_RECORDS`.
- `group_id`: the intended lowercase group, such as `com.acme`, or the
  organization's existing group. Reservation is needed only at registration.
- `template`: `custom-source` (SDK-only MVP), `api-source`, or `sql-source`.
- `version`: a development version such as `0.1.0.dev1` for a new project.
- For a real integration: authentication, objects, fields, pagination, rate
  limits and incremental behavior; credential variable names, never values.
- Only for a requested live test: organization/workspace, running Docker agent
  container, accessible destination/project, and expected source rows.

Choose `custom-source` for the minimal SDK example unless the user's source needs
one of the higher-level adapters. Existing projects keep their chosen template.
These are source templates, not standalone destination/activation templates.

## Prerequisites

- Node.js 18+ and a Supaflow CLI build that includes authoring. Run
  `supaflow connectors --help`; confirm `init`, `check`, `test`, `lock`, and
  `build` exist. If missing, report that the installed CLI lacks the required
  authoring commands; do not edit its feature flag or invent a command.
- An installed Python compatible with the selected CLI bundle and `uv` on PATH.
  The CLI selects an installed interpreter without downloading Python; it
  manages the toolchain and project environment. Use `connectors doctor` on an
  existing project for diagnostics. Do not install the old all-in-one package
  as a substitute for the selected SDK/runtime.
- For organization operations, a Supaflow account, CLI authentication and the
  intended organization/workspace. Group reservation and registration require
  an organization administrator or personal-account owner. Use
  [existing CLI setup](https://www.supa-flow.io/docs/cli#enable-access-and-authenticate).
- For deployment, Docker access to the already-running target private agent,
  a compatible agent image, and its persistent storage. Link to the
  [Docker agent guide](https://www.supa-flow.io/docs/settings/agents#deploying-a-self-hosted-docker-agent)
  for enrollment, approval and lifecycle; do not duplicate them here.
- For an E2E test, the agent must reach the source, destination and any required
  dependency sources. Use existing approved fixtures or a sandbox, not a new
  disposable database. Have exact locked SDK/runtime wheels if absent on the
  agent. No runtime-wheel download command is implied by this skill.

Local authoring does not need a CLI login, reserved group, enrolled agent or
live credentials. Use the intended group in the project, but reserve it only
when the user's authorized task includes organization registration. Local
Docker deployment also needs no CLI login or registration.

## Scaffold and Prove the MVP

For a new project, use the CLI rather than hand-writing packaging or locks:

```bash
supaflow connectors init ./mvp-records --template custom-source \
  --name MVP_RECORDS --group com.acme --display-name "MVP Records" \
  --connector-version 0.1.0.dev1
supaflow connectors check --project ./mvp-records
supaflow connectors test --project ./mvp-records
```

Substitute the actual inputs. Do not run `init` over an existing project.
The SDK-only starter declares a required `recordPrefix` property, discovers
`records` with an `id` primary key, and emits `example-1` and `example-2` when
configured with `example`. Run its generated tests before extending it.

Implement through the project's existing SDK/adapters and tests:

| Area | Required behavior and evidence |
|---|---|
| Definition and properties | Declare actual connection settings and capabilities. Test invalid required configuration without revealing credentials. |
| Connection test | `init` validates configuration/authentication and returns its result. Do not create customer tables or namespaces as a connection probe. |
| Discovery and refresh | `schema` returns the intended objects, fields, types and keys; exercise a second schema request. Use existing SDK/testkit schema validation. `SOURCE_KEY` is the wire identity strategy for source primary keys, not `SOURCE_PRIMARY_KEY`. |
| Source read | Read the discovered object and compare exact expected rows, not just counts. Respect field selection and cancellation; test incremental state only when implemented/advertised. |
| Role boundary | Keep the generated source-only unsupported write behavior. Do not require Java destination stubs or add no-op implementations just to satisfy the platform verifier. |

Edit `src/.../connector.py`, `source.py`, `schemas.py` and the fixture/tests
rather than generated artifact files. Use the generated `ConnectorHarness`
pattern and installed SDK interfaces; do not introduce another test framework,
custom loader, cache, scheduler or database admission checks.

After definition changes, generate the manifest and check again:

```bash
supaflow connectors manifest generate --project ./mvp-records
supaflow connectors check --project ./mvp-records
supaflow connectors test --project ./mvp-records
```

After reviewing dependency edits, run `connectors lock --project ./mvp-records`
explicitly, then the checks/tests. Keep locks in the project. Use
`lock --upgrade-runtime` only when a runtime upgrade is requested. Ordinary
checks/builds do not repair locks or silently change dependencies. Live tests
are opt-in with `test --live`; keep fixture tests independent of real secrets.

```bash
supaflow connectors build --project ./mvp-records --json
```

Use the returned `artifactDir`, not a guessed filename. Deploy the whole artifact
directory. Never lower compatibility requirements just to make an older agent
accept a new SDK. Use a compatible image and preserve integrity/policy checks.

## Register and Deploy Only Within the Requested Scope

A request to author or locally test a connector is not authorization to register,
deploy, start an agent, publish packages, or change production. Honor any existing
explicit authorization instead of asking again. Do not print API keys, tokens,
private keys, environment files, or raw credential-bearing logs.

When organization registration is requested:

```bash
supaflow auth status
supaflow workspaces list
supaflow workspaces select <workspace-name>
supaflow connectors group register com.acme --json
supaflow connectors dev register --artifact <artifactDir> --json
supaflow connectors dev status <version-id> --artifact <artifactDir> --json
```

One unique group belongs to the organization; repeating the same reservation is
safe, but changing to another group is rejected. It can cover multiple connector
names and vendor display names. Identity comes from group plus local name:
`com.acme` + `MVP_RECORDS` -> `COM_ACME__MVP_RECORDS`; do not add `CUSTOM_`.
Registration sends metadata and locks, makes the version tenant-specific, and
requires no agent. Save its returned type, version ID and artifact identity.

When local deployment is requested, independently of registration:

```bash
supaflow connectors dev deploy --artifact <artifactDir> --name <agent-container>
# If exact SDK/runtime wheels are absent on the agent:
supaflow connectors dev deploy --artifact <artifactDir> --name <agent-container> \
  --runtime-wheels <matching-wheel-directory>
```

Deployment copies/prepares local files without a login or tenant lookup. It does
not register the connector, start/restart the agent or change provisioning mode.
If multiple agents can execute jobs, deploy to each applicable agent. Registration
does not distribute wheels; a job arriving at an agent that still lacks its
custom artifact fails normally. Leave scheduling and routing unchanged.

## Authorized End-to-End Test

Reuse an existing approved private agent and fixtures. Create a datasource from
the registered type and verify its connection and discovered objects:

```bash
supaflow datasources init --connector <registered-type> --name "MVP Source" \
  --role SOURCE --output ./mvp-source.env
# Fill declared settings privately; recordPrefix=example for the unchanged MVP.
supaflow datasources create --from ./mvp-source.env --role SOURCE --json
supaflow datasources catalog <source-id> --refresh --output ./objects.json
```

Wait for discovery to complete; connection success alone is not schema success.
Use an existing destination/project or create them only within the authorized
scope. Review object selections and the generated config before running:

```bash
supaflow pipelines init --source <source-id> --project <project-id> \
  --output ./pipeline-config.json
supaflow pipelines create --name "MVP Pipeline" --source <source-id> \
  --project <project-id> --config ./pipeline-config.json --objects ./objects.json --json
supaflow pipelines sync <pipeline-id> --json
supaflow jobs get <job-id> --json
```

Monitor to a terminal result; queued/running is not success. Check per-object
read/load metrics and query the destination to compare exact expected values
and detect missing/extra rows. Do not add a schedule just to test a sync.
Retain redacted commands and terminal logs, plus actual screenshots when requested.
Close task-owned temporary browsers/profiles and sessions when done; preserve
shared infrastructure, identities, volumes and unrelated user work. Restore any
temporarily changed pins or settings and identify remaining blockers honestly.

## Iteration and Completion

- For changed artifact bytes, bump the development version in `pyproject.toml`,
  regenerate the manifest, refresh dependency locks if needed, and test/build
  again. Do not overwrite a registered/deployed version with different bytes.
- Registration of a new version does not repin existing datasources. For a
  development iteration, create a new test datasource for that version unless
  an existing supported upgrade workflow is explicitly being used.
- Checkout recovery can remove locally deployed artifacts; deploy them again.
- Report the project/template/version, checks actually run, artifact directory,
  and remaining gaps. Report registration/deployment/E2E only if performed.
  Local unit tests do not prove agent compatibility or destination values.
- Do not publish SDK/connector packages or deploy to production unless the user
  separately requested those actions. Installing this skill enables no release.
