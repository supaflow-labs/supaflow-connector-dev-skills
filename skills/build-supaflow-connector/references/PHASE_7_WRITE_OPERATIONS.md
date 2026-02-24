# Phase 7: Write Operations (Destination Connectors)

**Objective**: Implement destination connector capabilities: stage(), load(), executeSqlScript(), mapToTargetObject(), and getCapabilitiesConfig().

**Time Estimate**: 120-180 minutes

**Prerequisite**: Phases 1-6 completed. This phase is ONLY for connectors that support being a destination (not source-only connectors).

---

## Table of Contents

- [Required Methods for Destination Connectors (Do Not Skip)](#required-methods-for-destination-connectors-do-not-skip)
- [Prerequisites](#prerequisites)
- [Cancellation in Stage/Load (Required)](#cancellation-in-stageload-required)
- [Understanding the Destination Flow](#understanding-the-destination-flow)
- [Understanding Key Enums](#understanding-key-enums)
- [Step 1: Implement getCapabilitiesConfig()](#step-1-implement-getcapabilitiesconfig)
- [Step 2: Implement mapToTargetObject()](#step-2-implement-maptotargetobject)
- [Step 3: Implement stage()](#step-3-implement-stage)
- [Step 4: Implement load()](#step-4-implement-load)
- [Step 5: Implement executeSqlScript()](#step-5-implement-executesqlscript)
- [Step 5.5: Propagating Sync Metadata (syncTime, sync_id) Critical](#step-55-propagating-sync-metadata-synctime-sync_id-critical)
- [Step 6: Build Destination Integration Tests](#step-6-build-destination-integration-tests)
- [Gate Verification](#gate-verification)
- [Common Mistakes to Avoid](#common-mistakes-to-avoid)

---

## Required Methods for Destination Connectors (Do Not Skip)

Even destination-only connectors must implement identifier formatting methods because the pipeline calls them during mapping before stage/load.

**Required:**
- `getCapabilitiesConfig()`
- `mapToTargetObject(...)`
- `stage(...)`
- `load(...)`
- `getIdentifierFormatter()`
- `getIdentifierQuoteString()`
- `getIdentifierSeparator()`
- `getFullyQualifiedSchemaName(...)`
- `getFullyQualifiedTableName(...)`

**Optional:**
- `executeSqlScript(...)` (implement if connector supports SQL; otherwise throw `UnsupportedOperationException`)

**Destination-only connectors may keep these as UnsupportedOperationException:**
- `read(...)`
- `validateReadRequest(...)`
- `identifyCursorFields(...)`

---

## Prerequisites

### Essential Reading (MUST read before starting)

**CRITICAL**: You MUST read these SDK classes before implementing destination operations.

| File | What to Learn | Why It Matters |
|------|---------------|----------------|
| `supaflow-connector-sdk/.../SupaflowConnector.java` | Interface definition | All methods you must implement |
| `supaflow-connector-sdk/.../model/StageRequest.java` | Stage request structure | Inputs for staging data |
| `supaflow-connector-sdk/.../model/StageResponse.java` | Stage response structure | What to return after staging |
| `supaflow-connector-sdk/.../model/LoadRequest.java` | Load request structure | Inputs for loading data |
| `supaflow-connector-sdk/.../model/LoadResponse.java` | Load response structure | What to return after loading |
| `supaflow-connector-sdk/.../model/SqlScriptRequest.java` | SQL script request | Inputs for SQL execution |
| `supaflow-connector-sdk/.../model/SqlScriptResponse.java` | SQL script response | What to return after execution |
| `supaflow-connector-sdk/.../util/ConnectorCapabilitiesConfigBuilder.java` | Capabilities builder | How to define connector capabilities |
| `supaflow-connector-snowflake/.../SnowflakeConnector.java` | Reference implementation | Complete destination example |

### Find and Read SDK Classes

```bash
PLATFORM_ROOT="<platform-root>"
REFERENCE_DESTINATION_CONNECTOR="${REFERENCE_DESTINATION_CONNECTOR:-snowflake}"

# MUST read these files before proceeding
find "$PLATFORM_ROOT" -name "StageRequest.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "StageResponse.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "LoadRequest.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "LoadResponse.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "SqlScriptRequest.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "ConnectorCapabilitiesConfigBuilder.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;

# Read Snowflake connector as reference
grep -A 100 "public StageResponse stage(" \
  "$PLATFORM_ROOT"/connectors/supaflow-connector-"$REFERENCE_DESTINATION_CONNECTOR"/src/main/java/**/*.java
grep -A 100 "public LoadResponse load(" \
  "$PLATFORM_ROOT"/connectors/supaflow-connector-"$REFERENCE_DESTINATION_CONNECTOR"/src/main/java/**/*.java
```

If no destination reference connector exists locally, follow this phase strictly and validate with destination checks 16-24 before handoff.

### Confirm Understanding

Before proceeding, you MUST be able to answer:

1. What is the difference between `stage()` and `load()`?
2. What does `LoadMode` contain? (APPEND, MERGE, OVERWRITE, TRUNCATE_AND_LOAD)
3. What is `DestinationTableHandling`? (FAIL, DROP, MERGE)
4. What is `mapToTargetObject()` used for?
5. How does `ConnectorCapabilitiesConfigBuilder` work?
6. What is the `SqlScriptResultProcessor` lifecycle?

---

## Cancellation in Stage/Load (Required)

- Check cancellation during file uploads, batch writes, and any long-running loops.
- For JDBC-based destinations, register/clear statements around COPY/MERGE/DDL queries.
- Do not retry `ConnectorException.ErrorType.CANCELLED`.
- If using executor shutdown waits, poll frequently (1-5s) and honor cancellation immediately.

---

## Understanding the Destination Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        EXECUTOR                                  │
│                                                                  │
│  1. Calls read() on SOURCE connector                            │
│  2. Writes data to local CSV files                              │
│  3. Calls mapToTargetObject() on DESTINATION connector          │
│  4. Calls stage() to upload data to staging area                │
│  5. Calls load() to load data into final tables                 │
│  6. May call executeSqlScript() for custom operations           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    DESTINATION CONNECTOR                         │
│                                                                  │
│  mapToTargetObject(): Map source schema to target format        │
│  stage():   Upload CSV files to staging location (e.g., S3)     │
│  load():    Copy from staging to final tables (COPY/MERGE)      │
│  executeSqlScript(): Execute arbitrary SQL                      │
│                                                                  │
│  getCapabilitiesConfig(): Define what the connector supports    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Understanding Key Enums

### LoadMode (How to handle data loading)

| Mode | Description | Use Case |
|------|-------------|----------|
| `APPEND` | Insert all rows (may have duplicates) | Append-only logs, events |
| `MERGE` | Upsert based on primary key | Typical transactional sync |
| `OVERWRITE` | Drop and recreate table | Full refresh |
| `TRUNCATE_AND_LOAD` | Truncate then insert | Full refresh, keep schema |

### DestinationTableHandling (First run behavior)

| Mode | Description | When to Use |
|------|-------------|-------------|
| `FAIL` | Error if table exists | Strict mode |
| `DROP` | Drop existing table | Clean slate |
| `MERGE` | Merge with existing | Preserve data |

---

## Step 1: Implement getCapabilitiesConfig()

This defines what your connector supports and is used by the UI to show/hide options.

```java
@Override
public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
    return ConnectorCapabilitiesConfigBuilder.builder()
        // Connector type preset
        .asCloudWarehouse()  // OR .asTraditionalDatabase() OR .asAPIConnector()

        // Load modes this connector supports
        .loadModes(LoadMode.APPEND, LoadMode.MERGE, LoadMode.OVERWRITE, LoadMode.TRUNCATE_AND_LOAD)
        .defaultLoadMode(LoadMode.MERGE)

        // Destination table handling options
        .destinationTableHandlings(DestinationTableHandling.FAIL, DestinationTableHandling.DROP, DestinationTableHandling.MERGE)
        .defaultDestinationTableHandling(DestinationTableHandling.MERGE)

        // Schema capabilities
        .canAutoCreateSchema(true)
        .schemaEvolutionModes(SchemaEvolutionMode.ALLOW_ALL, SchemaEvolutionMode.ALLOW_NEW_COLUMNS_ONLY)
        .defaultSchemaEvolutionMode(SchemaEvolutionMode.ALLOW_ALL)

        // Staging (for cloud warehouses)
        .supportsStaging(true)
        .requiresStaging(true)  // Set to true if staging is mandatory
        .requiresExplicitLoadStep(true)

        // Other capabilities
        .supportsHardDeletes(true)
        .canPropagateEmptySchema(true)

        // Performance features
        .supportsParallelization(true)
        .supportsCheckpointing(false)

        .build();
}
```

### Convenience Presets

```java
// Cloud data warehouse (Snowflake, BigQuery, Redshift)
.asCloudWarehouse()
// Sets: optimization=COST, modes=COST+LATENCY

// Traditional database (PostgreSQL, MySQL, Oracle)
.asTraditionalDatabase()
// Sets: canAutoCreateSchema=true, hardDeletes=true, optimization=LATENCY

// API-based connector (Salesforce, HubSpot)
.asAPIConnector()
// Sets: hardDeletes=false, canAutoCreateSchema=false, rateLimit=true
```

---

## Step 2: Implement mapToTargetObject()

Maps source object metadata to destination-compatible format.

### ⚠️ CRITICAL REQUIREMENTS

**YOU MUST:**
1. ✅ Apply `NamespaceRules` for schema/table/column names (includes pipeline prefix)
2. ✅ Preserve `customAttributes` from source object (connector-specific metadata, not sync metadata)
3. ✅ Normalize identifiers per connector conventions (lowercase, uppercase, etc.)

**YOU MUST NOT:**
1. ❌ Add tracking columns (`_supa_synced`, `_supa_job_id`, `_supa_deleted`)
   - The platform's writer/schema mapper adds these automatically
   - Adding them here will cause duplicates and break schema generation

2. ❌ Ignore `NamespaceRules` parameters
   - Pipeline prefix MUST be applied via NamespaceRules
   - Ignoring this causes tables to have wrong names in destination

**File-based destinations (S3, GCS, etc.)**
- Use `NamespaceRules.getSchemaName()` and `getTableName()` even if the destination has no schema.
- Put schema in the **path prefix** (and Glue database, if applicable), not in the file name.
- Use schema + table as distinct path segments; do not concatenate schema/table into a single identifier.
- If a catalog is involved (Glue, Hive, etc.), use the computed schema as the database name and the table name as the table.

```java
@Override
public ObjectMetadata mapToTargetObject(ObjectMetadata sourceObj,
                                        NamespaceRules namespaceRules,
                                        ObjectMetadata existingMappedObj) throws ConnectorException {

    // Step 1: Resolve target catalog/schema/table names using namespace rules
    String targetCatalog = namespaceRules.getDatabaseName(
        getType().toUpperCase(),  // "SNOWFLAKE", "POSTGRES", etc.
        getIdentifierQuoteString(),
        isIdentifierCaseSensitive(),
        getDefaultCatalog(),
        getDefaultSchema(),
        sourceObj.getCatalog(),
        sourceObj.getSchema()
    );

    if (targetCatalog == null) {
        targetCatalog = getDefaultCatalog();
    }

    String targetSchema = namespaceRules.getSchemaName(
        getType().toUpperCase(),
        getIdentifierQuoteString(),
        isIdentifierCaseSensitive(),
        getDefaultCatalog(),
        getDefaultSchema(),
        sourceObj.getCatalog(),
        sourceObj.getSchema()
    );

    if (targetSchema == null) {
        targetSchema = getDefaultSchema();
    }

    String targetTableName = namespaceRules.getTableName(
        getIdentifierFormatter().getKeywordProvider().getReservedKeywords(),
        getType().toUpperCase(),
        getIdentifierQuoteString(),
        isIdentifierCaseSensitive(),
        getDefaultCatalog(),
        getDefaultSchema(),
        sourceObj.getCatalog(),
        sourceObj.getSchema(),
        sourceObj.getName()
    );

    if (targetTableName == null) {
        throw new ConnectorException(
            "Table name is null after applying namespace rules for source: " + sourceObj.getName(),
            ConnectorException.ErrorType.VALIDATION_ERROR
        );
    }

    // Step 2: Apply connector-specific naming conventions
    // (e.g., Snowflake uppercases unquoted identifiers)
    targetCatalog = applyNamingConvention(targetCatalog);
    targetSchema = applyNamingConvention(targetSchema);
    targetTableName = applyNamingConvention(targetTableName);

    // Step 3: Create target ObjectMetadata
    ObjectMetadata mappedObj = new ObjectMetadata();
    mappedObj.setCatalog(targetCatalog);
    mappedObj.setSchema(targetSchema);
    mappedObj.setName(targetTableName);
    mappedObj.setDescription(sourceObj.getDescription());
    mappedObj.setType(sourceObj.getType());
    mappedObj.setSkipped(sourceObj.getSkipped());
    mappedObj.setSkippedReason(sourceObj.getSkippedReason());
    mappedObj.setSelected(sourceObj.getSelected());
    mappedObj.setPrimaryKeyLocked(sourceObj.getPrimaryKeyLocked());
    mappedObj.setCursorFieldLocked(sourceObj.getCursorFieldLocked());

    // Preserve connector-specific metadata
    if (sourceObj.getCustomAttributes() != null) {
        mappedObj.setCustomAttributes(new HashMap<>(sourceObj.getCustomAttributes()));
    }

    // Step 4: Set fully qualified name
    setFullyQualifiedNames(mappedObj, targetCatalog, targetSchema, targetTableName);

    // Step 5: Map each field
    List<FieldMetadata> mappedFields = new ArrayList<>();
    if (sourceObj.getFields() != null) {
        for (FieldMetadata sourceField : sourceObj.getFields()) {
            FieldMetadata mappedField = mapToTargetField(
                sourceObj, namespaceRules, sourceField, targetTableName, existingMappedObj
            );
            mappedFields.add(mappedField);
        }
    }
    mappedObj.setFields(mappedFields);

    // Step 6: Populate formatted names for DDL generation
    populateFormattedNames(mappedObj);

    return mappedObj;
}

/**
 * Maps a source field to target field with proper naming and type conversion.
 */
private FieldMetadata mapToTargetField(ObjectMetadata sourceObj,
                                       NamespaceRules namespaceRules,
                                       FieldMetadata sourceField,
                                       String targetTableName,
                                       ObjectMetadata existingMappedObj) throws ConnectorException {

    // Get target column name from namespace rules
    String targetColumnName = namespaceRules.getColumnName(
        getIdentifierFormatter().getKeywordProvider().getReservedKeywords(),
        getType().toUpperCase(),
        getIdentifierQuoteString(),
        isIdentifierCaseSensitive(),
        getDefaultCatalog(),
        getDefaultSchema(),
        sourceObj.getCatalog(),
        sourceObj.getSchema(),
        sourceObj.getName(),
        sourceField.getName()
    );

    if (targetColumnName == null) {
        throw new ConnectorException(
            "Column name is null after applying namespace rules for: " + sourceField.getName(),
            ConnectorException.ErrorType.VALIDATION_ERROR
        );
    }

    // Apply naming convention
    targetColumnName = applyNamingConvention(targetColumnName);

    // Create mapped field
    FieldMetadata mappedField = new FieldMetadata();
    mappedField.setName(targetColumnName);
    mappedField.setDescription(sourceField.getDescription());
    mappedField.setSelected(sourceField.getSelected());
    mappedField.setNullable(sourceField.getNullable());
    mappedField.setPrimaryKey(sourceField.isPrimaryKey());
    mappedField.setSourcePrimaryKey(sourceField.isSourcePrimaryKey());
    mappedField.setCursorField(sourceField.isCursorField());
    mappedField.setSourcePath(sourceField.getSourcePath());

    // Map canonical type (may widen if existing field has wider type)
    CanonicalType targetType = sourceField.getCanonicalType();
    if (existingMappedObj != null) {
        FieldMetadata existingField = existingMappedObj.getField(targetColumnName);
        if (existingField != null &&
            TypeHierarchy.isSubtypeOf(sourceField.getCanonicalType(), existingField.getCanonicalType())) {
            targetType = existingField.getCanonicalType();
        }
    }
    mappedField.setCanonicalType(targetType);

    // Map to connector-specific data type
    String nativeType = mapCanonicalToNativeType(targetType, sourceField.getPrecision(), sourceField.getScale());
    mappedField.setOriginalDataType(nativeType);

    // Copy precision/scale
    mappedField.setPrecision(sourceField.getPrecision());
    mappedField.setScale(sourceField.getScale());

    return mappedField;
}

/**
 * Maps canonical type to native database type.
 * MUST be implemented by each connector.
 */
protected abstract String mapCanonicalToNativeType(CanonicalType type, Integer precision, Integer scale);
```

---

## Step 3: Implement stage()

Uploads data files to a staging location (cloud storage, internal stage, etc.).

```java
@Override
public StageResponse stage(StageRequest request) throws ConnectorException {
    try {
        String stageLocation = uploadToStage(
            request.getLocalDataPath(),
            request.getMetadataMapping(),
            request.getFileFormat(),
            request.getCallback()
        );
        return StageResponse.success(stageLocation);
    } catch (Exception e) {
        log.error("Failed to stage data", e);
        throw new ConnectorException(
            "Stage failed: " + e.getMessage(),
            e,
            ConnectorException.ErrorType.IO_ERROR
        );
    }
}

/**
 * Implementation-specific staging logic.
 * Returns the stage location path for use in load().
 */
protected String uploadToStage(String localDataPath,
                               PipelineMetadataMappingAndSourceMetadataCatalog metadataMapping,
                               FileFormat fileFormat,
                               ConnectorCallback callback) throws Exception {

    // Example for Snowflake:
    // 1. Create internal stage if doesn't exist
    // 2. PUT files from localDataPath to stage
    // 3. Return stage path (e.g., "@MY_STAGE/pipeline_123/")

    // Example for S3-backed destinations:
    // 1. Upload files to S3 bucket
    // 2. Return S3 path (e.g., "s3://bucket/prefix/")

    // Example for direct load (no staging):
    // 1. Return null or empty string
    // 2. load() will read directly from localDataPath

    throw new UnsupportedOperationException("uploadToStage must be implemented");
}
```

### For Connectors That Don't Need Staging

If your connector loads directly from local files (no staging area):

```java
@Override
public StageResponse stage(StageRequest request) throws ConnectorException {
    // No staging needed - load() will read directly from localDataPath
    return StageResponse.noOp("Direct load mode - no staging required");
}
```

---

## Step 4: Implement load()

Loads data from staging into target tables.

```java
@Override
public LoadResponse load(LoadRequest request) throws ConnectorException {
    try {
        // DDL-only mode: just create/alter tables, no data load
        if (request.isDdlOnly()) {
            executeDdl(request.getMetadataMapping());
            return LoadResponse.success("DDL executed");
        }

        // Zero rows: create empty table structure
        if (request.isZeroRows()) {
            createEmptyTable(request.getMetadataMapping());
            return LoadResponse.success("Empty table created");
        }

        // Check if we have staged data
        if (request.getStageLocation() != null && !request.getStageLocation().isEmpty()) {
            // COPY INTO path (from staging)
            executeCopyInto(
                request.getStageLocation(),
                request.getMetadataMapping(),
                request.getFileFormat(),
                request.getCallback(),
                request.isZeroRows(),
                request.isDdlOnly()
            );

            // Then execute MERGE to final table
            executeMerge(
                request.getLoadMode(),
                request.getDestinationTableHandlingMode(),
                request.getMetadataMapping(),
                request.getCallback()
            );

            return LoadResponse.success("COPY + MERGE executed");

        } else if (request.getLocalDataPath() != null) {
            // Direct load path (from local files)
            return executeDirectLoad(
                request.getLocalDataPath(),
                request.getLoadMode(),
                request.getDestinationTableHandlingMode(),
                request.getMetadataMapping(),
                request.getCallback()
            );

        } else {
            throw new ConnectorException(
                "Neither stageLocation nor localDataPath provided",
                ConnectorException.ErrorType.VALIDATION_ERROR
            );
        }

    } catch (Exception e) {
        log.error("Load failed", e);
        throw new ConnectorException(
            "Load failed: " + e.getMessage(),
            e,
            ConnectorException.ErrorType.SQL_ERROR
        );
    }
}
```

### Execute COPY INTO (Cloud Warehouses)

```java
/**
 * Executes COPY INTO from stage to staging table.
 */
protected void executeCopyInto(String stageLocation,
                               PipelineMetadataMappingAndSourceMetadataCatalog metadataMapping,
                               FileFormat fileFormat,
                               ConnectorCallback callback,
                               boolean zeroRows,
                               boolean isDdlOnly) throws Exception {

    ObjectMetadata objectMetadata = metadataMapping.getMappedMergedSourceMetadata();

    // 1. Create staging table (clone of target structure)
    String stageTableName = createStageTable(objectMetadata);

    // 2. Skip COPY if no data
    if (zeroRows) {
        log.info("No data to load - created empty staging table");
        callback.update(new CallbackStatusDto(
            0L, 0L, 0L, 0L, null, 0L, null, null, null, null,
            System.currentTimeMillis(), System.currentTimeMillis(),
            null, "Created empty staging table", null, CallbackStatus.ENDED
        ));
        return;
    }

    // 3. Create file format
    String fileFormatName = createFileFormat(objectMetadata, fileFormat);

    // 4. Execute COPY INTO
    String copyIntoSql = buildCopyIntoSql(objectMetadata, stageTableName, fileFormatName, stageLocation);
    executeStatement(copyIntoSql);

    // 5. Report progress
    callback.update(new CallbackStatusDto(
        /* rowsParsed, rowsLoaded, errors, files, etc. */
        "COPY INTO completed", null, CallbackStatus.ENDED
    ));
}
```

### Execute MERGE (Final Load)

```java
/**
 * Executes MERGE from staging table to target table.
 */
protected void executeMerge(LoadMode loadMode,
                            DestinationTableHandling destinationTableHandlingMode,
                            PipelineMetadataMappingAndSourceMetadataCatalog metadataMapping,
                            ConnectorCallback callback) throws Exception {

    ObjectMetadata stageMetadata = metadataMapping.getMappedMergedSourceMetadata();
    ObjectMetadata expectedDestMetadata = metadataMapping.getMappedLastAppliedSourceMetadata();

    boolean isFirstRun = expectedDestMetadata == null;
    boolean targetExists = checkTableExists(stageMetadata);

    List<String> sqlStatements = new ArrayList<>();

    if (!targetExists) {
        // First time: rename staging table to target
        sqlStatements.addAll(buildRenameQuery(stageMetadata));
    } else {
        // Target exists: apply load mode
        switch (loadMode) {
            case OVERWRITE:
                sqlStatements.addAll(buildDropAndRenameQuery(stageMetadata));
                break;

            case TRUNCATE_AND_LOAD:
                sqlStatements.add("TRUNCATE TABLE " + getFullyQualifiedName(stageMetadata));
                sqlStatements.add(buildInsertSql(stageMetadata));
                break;

            case APPEND:
                sqlStatements.add(buildInsertSql(stageMetadata));
                break;

            case MERGE:
                sqlStatements.add(buildMergeSql(stageMetadata));
                break;
        }
    }

    // Execute all SQL statements
    for (String sql : sqlStatements) {
        executeStatement(sql);
    }

    // Cleanup staging table (if not renamed)
    if (targetExists && loadMode != LoadMode.OVERWRITE) {
        dropStageTable(stageMetadata);
    }

    callback.update(new CallbackStatusDto(
        "MERGE completed", null, CallbackStatus.ENDED
    ));
}
```

---

## Step 5: Implement executeSqlScript()

Executes arbitrary SQL scripts against the database.

**Note**: For JDBC-based connectors, `BaseJdbcConnector` provides a complete implementation. You typically don't need to override this unless you have special requirements.

```java
@Override
public SqlScriptResponse executeSqlScript(SqlScriptRequest request) throws ConnectorException {
    // For JDBC connectors: use super implementation
    return super.executeSqlScript(request);

    // For non-JDBC connectors: implement custom logic
}
```

### Custom Implementation (Non-JDBC)

```java
@Override
public SqlScriptResponse executeSqlScript(SqlScriptRequest request) throws ConnectorException {
    if (request == null || request.getScriptContent() == null || request.getProcessor() == null) {
        throw new ConnectorException(
            "Invalid request: scriptContent and processor are required",
            ConnectorException.ErrorType.VALIDATION_ERROR
        );
    }

    long startTime = System.currentTimeMillis();
    int statementsExecuted = 0;
    SqlScriptResultProcessor processor = request.getProcessor();

    try {
        // Parse SQL into individual statements
        List<String> statements = parseSqlStatements(request.getScriptContent());

        for (int i = 0; i < statements.size(); i++) {
            String statement = statements.get(i);
            int statementIndex = i + 1;

            try {
                processor.onStatementStart(statementIndex, statement);
                long statementStartTime = System.currentTimeMillis();

                if (isSelectStatement(statement)) {
                    // Stream SELECT results through processor
                    executeSelectAndStream(statement, statementIndex, processor);
                } else {
                    // Execute DML/DDL
                    int rowsAffected = executeDmlDdl(statement);
                    long executionTime = System.currentTimeMillis() - statementStartTime;
                    processor.onStatementComplete(statementIndex, rowsAffected, executionTime);
                }

                statementsExecuted++;

            } catch (Exception e) {
                log.error("Statement {} failed: {}", statementIndex, e.getMessage());
                processor.onStatementError(statementIndex, e);

                SqlScriptProcessingResult result = processor.onScriptComplete(false);
                return SqlScriptResponse.builder()
                    .success(false)
                    .statementsExecuted(statementsExecuted)
                    .errorMessage("Statement " + statementIndex + " failed: " + e.getMessage())
                    .processingResult(result)
                    .build();
            }
        }

        SqlScriptProcessingResult result = processor.onScriptComplete(true);
        long totalTime = System.currentTimeMillis() - startTime;

        return SqlScriptResponse.success(totalTime, statementsExecuted, result);

    } catch (Exception e) {
        log.error("Script execution failed", e);
        SqlScriptProcessingResult result = processor.onScriptComplete(false);
        return SqlScriptResponse.builder()
            .success(false)
            .errorMessage("Script failed: " + e.getMessage())
            .processingResult(result)
            .build();
    }
}
```

---

## Step 5.5: Propagating Sync Metadata (syncTime, sync_id) ⭐ CRITICAL

### The Problem

Destination connectors need to use the **SAME** sync metadata as ingestion:
- **syncTime**: The ingestion cutoff timestamp for the job
- **sync_id**: The job ID for tracking which sync wrote which data
  - `syncTime` is derived from `SyncStateRequest.cutoffTime` (persisted in endState) and passed to stage/load by the pipeline.

**ANTI-PATTERN**: Using `Instant.now()` or `UUID.randomUUID()` creates inconsistency:
```java
// ❌ WRONG - Different time than ingestion
Instant syncTime = Instant.now();  // Will be different in stage() vs load()

// ❌ WRONG - Not the actual job ID
String syncId = UUID.randomUUID().toString();  // Random, not job_id
String syncId = jobContext.toString();  // Object reference, not ID
```

### The Solution: Use request.syncTime + Job ID

The pipeline sets `syncTime` on both `StageRequest` and `LoadRequest`. Treat it as required and use it everywhere (partitions, tracking columns, Glue metadata). Do not compute your own syncTime in the connector.

```java
@Override
public StageResponse stage(StageRequest request) throws ConnectorException {
    Instant syncTime = request.getSyncTime();
    if (syncTime == null) {
        throw new ConnectorException("syncTime is required in StageRequest",
            ConnectorException.ErrorType.VALIDATION_ERROR);
    }
    String syncId = resolveSyncId();

    // Use this syncTime for:
    // - Partition values (year/month/day/hour)
    // - _supa_synced column value
    // - File timestamps
}

@Override
public LoadResponse load(LoadRequest request) throws ConnectorException {
    Instant syncTime = request.getSyncTime();
    if (syncTime == null) {
        throw new ConnectorException("syncTime is required in LoadRequest",
            ConnectorException.ErrorType.VALIDATION_ERROR);
    }
    String syncId = resolveSyncId();

    // Use for Glue partitions, table metadata, MERGE conditions, etc.
}
```

#### 2. Getting sync_id

```java
private String resolveSyncId() {
    Object jobContext = runtimeContext.getJobContext();

    if (jobContext instanceof Job) {
        // CORRECT - Get actual job ID
        return ((Job) jobContext).getId();
    }

    // Fallback (shouldn't happen)
    log.warn("JobContext is not a Job instance, using fallback sync_id");
    return UUID.randomUUID().toString();
}
```

#### 3. Using in Partitions/Metadata

```java
// Example: S3 partitions
String year = String.format("%04d", syncTime.atZone(ZoneOffset.UTC).getYear());
String month = String.format("%02d", syncTime.atZone(ZoneOffset.UTC).getMonthValue());
String day = String.format("%02d", syncTime.atZone(ZoneOffset.UTC).getDayOfMonth());
String hour = String.format("%02d", syncTime.atZone(ZoneOffset.UTC).getHour());

String s3Path = String.format("%s/year=%s/month=%s/day=%s/hour=%s/sync_id=%s/",
    basePrefix, year, month, day, hour, syncId);

// Example: Glue catalog partition
Map<String, String> partitionValues = new HashMap<>();
partitionValues.put("YEAR", year);
partitionValues.put("MONTH", month);
partitionValues.put("DAY", day);
partitionValues.put("HOUR", hour);
partitionValues.put("SYNC_ID", syncId);
```

### Why This Matters

Without consistent sync metadata:
- ❌ Partitions have inconsistent timestamps
- ❌ `_supa_synced_at` doesn't match actual sync time
- ❌ `sync_id` is random, can't track data lineage
- ❌ Incremental syncs may skip or duplicate data

---

## Step 5.6: CSV File Discovery in stage() ⭐ CRITICAL

### The Problem

The platform writes CSV files with a specific naming convention, but the pattern is not obvious.

### Platform CSV Naming Convention

The executor writes TWO types of CSV files to `localDataPath`:

| File Pattern | Contents | Usage |
|--------------|----------|-------|
| `success_part_*.csv` | Successfully processed records | ✅ Upload these to destination |
| `error_part_*.csv` | Records that failed processing | ❌ DO NOT upload these |

**ANTI-PATTERN**: Looking for `<table_name>_*.csv`:
```java
// ❌ WRONG - This pattern doesn't match platform output
filter(p -> p.getFileName().toString().startsWith(tableName + "_"))
```

### The Solution

```java
@Override
public StageResponse stage(StageRequest request) throws ConnectorException {
    Path localDataPath = Paths.get(request.getLocalDataPath());

    // Find success CSV files - use correct pattern
    List<Path> csvFiles;
    try (Stream<Path> paths = Files.walk(localDataPath)) {
        csvFiles = paths
            .filter(Files::isRegularFile)
            .filter(p -> {
                String filename = p.getFileName().toString();
                // ✅ CORRECT - Match platform naming
                return filename.startsWith("success_part_") && filename.endsWith(".csv");
            })
            .collect(Collectors.toList());
    }

    if (csvFiles.isEmpty()) {
        log.info("No data files to stage");
        return StageResponse.success("No data to stage");
    }

    log.info("Found {} CSV files to stage", csvFiles.size());

    // Process each CSV file
    for (Path csvFile : csvFiles) {
        checkCancellation("file upload");
        uploadToStaging(csvFile, request);
    }

    return StageResponse.success("Staged " + csvFiles.size() + " files");
}
```

### Alternative: Pattern Matching

```java
// Using glob pattern
PathMatcher matcher = FileSystems.getDefault()
    .getPathMatcher("glob:**/success_part_*.csv");

List<Path> csvFiles = Files.walk(localDataPath)
    .filter(matcher::matches)
    .collect(Collectors.toList());
```

### Why This Matters

Without correct CSV discovery:
- ❌ `stage()` finds no files, uploads nothing
- ❌ Load fails silently (no data in staging area)
- ❌ Tests pass with simplified filenames but production fails
- ❌ Error records get uploaded to destination

---

## Step 5.7: CSV Parsing Must Honor CsvFileFormat (If You Parse Locally)

If the destination reads CSV files locally (e.g., S3/GCS converting CSV → Parquet),
you MUST use the `CsvFileFormat` from `StageRequest.getFileFormat()` to configure parsing.

**Required handling:**
- `skipHeader` (number of header rows; CursorTracking writes 2 rows)
- `fieldDelimiter`
- `fieldOptionallyEnclosedBy` (quote char)
- `escape`
- `trimSpace`
- `skipBlankLines`
- `nullIf` and `emptyFieldAsNull`
- `binaryFormat` (BASE64 vs raw bytes)

**Do NOT** auto-detect header rows or delimiters. The pipeline already sets a canonical CSV format.

---

## Step 6: Update ConnectorCapabilities

Update `getConnectorCapabilities()` to include destination capability:

```java
@Override
public Set<ConnectorCapabilities> getConnectorCapabilities() {
    return EnumSet.of(
        ConnectorCapabilities.REPLICATION_SOURCE,      // Can be a source
        ConnectorCapabilities.REPLICATION_DESTINATION  // Can be a destination
    );
}
```

---

## Snowflake Reference Implementation Summary

The Snowflake connector uses a three-phase approach:

```
1. stage()
   └── uploadToStage() → PUT files to @stage

2. load()
   ├── executeCopyInto() → COPY INTO staging_table FROM @stage
   └── executeMerge()    → MERGE/INSERT INTO target_table FROM staging_table

3. Cleanup
   └── Drop staging table
```

Key helper classes:
- `SnowflakeLoader`: Handles file uploads, COPY INTO, DDL generation
- `SnowflakeIdentifierUtils`: Formats identifiers with proper quoting
- `DataTypeMapper`: Maps canonical types to Snowflake types

---

## Gate Verification

### Automated Checks

```bash
# 1. Compile the project
cd connectors/supaflow-connector-{name}
mvn compile

# 2. Run verification script
cd ../..
bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>
```

### Expected Verification Results

| Check | Expected Result |
|-------|-----------------|
| CHECK 3 | ✓ Required methods (stage, load, mapToTargetObject) |
| CHECK 12 | ✓ Primary key identification in mapToTargetField |
| All checks | All 15 should pass |

### Manual Checklist

| Check | Verification |
|-------|--------------|
| ☐ getCapabilitiesConfig() returns valid config | Code review |
| ☐ mapToTargetObject() handles namespace rules | Code review |
| ☐ mapToTargetObject() maps all fields | Code review |
| ☐ mapToTargetField() sets correct types | Code review |
| ☐ stage() returns valid StageResponse | Code review |
| ☐ load() handles all LoadModes | Code review |
| ☐ load() handles DDL-only and zero-rows | Code review |
| ☐ executeSqlScript() works (if JDBC) | Test |
| ☐ ConnectorCapabilities includes DESTINATION | Code review |
| ☐ Identifier formatter methods implemented (no UnsupportedOperationException) | Code review |
| ☐ getIdentifierQuoteString/getIdentifierSeparator match naming rules | Code review |

### Unit Tests (Naming/Paths)

Add lightweight unit tests for naming and path generation (no live services):

1. **NamespaceRules mapping**
   - `mapToTargetObject()` uses `NamespaceRules.getSchemaName()` and `getTableName()`
   - Schema/table names are normalized per connector conventions
2. **File destination paths**
   - Base path includes configured prefix + schema + table
   - Schema is a distinct path segment (not concatenated into file name)
3. **Catalog mapping (Glue/Hive)**
   - Computed schema name is used as database/catalog name
   - Table name remains the mapped table name

### Verification Commands

```bash
# Check for destination capability
grep -n "REPLICATION_DESTINATION" src/main/java/**/*.java

# Check for stage implementation
grep -n "public StageResponse stage" src/main/java/**/*.java

# Check for load implementation
grep -n "public LoadResponse load" src/main/java/**/*.java

# Check for mapToTargetObject
grep -n "public ObjectMetadata mapToTargetObject" src/main/java/**/*.java

# Check for capabilities config
grep -n "getCapabilitiesConfig" src/main/java/**/*.java
```

---

## Common Mistakes to Avoid

| Mistake | Why It's Wrong | Correct Approach |
|---------|----------------|------------------|
| **Not implementing getCapabilitiesConfig()** | UI won't show correct options | Define all supported capabilities |
| **Ignoring namespace rules** | Wrong table/column names | Always use namespace rules for naming |
| **Not handling LoadMode.MERGE** | Duplicates on every sync | Implement proper MERGE logic |
| **Skipping DDL-only handling** | Schema propagation fails | Handle isDdlOnly() flag |
| **Not cleaning up staging tables** | Orphaned tables accumulate | Drop staging tables after load |
| **Hardcoding identifiers** | Reserved word conflicts | Use identifier formatter |
| **Not setting DESTINATION capability** | Connector won't show as destination | Add to getConnectorCapabilities() |

---

## Dual Source/Destination Connectors

For connectors that can be both source and destination (like PostgreSQL):

1. Implement ALL source methods (Phases 1-6)
2. Implement ALL destination methods (Phase 7)
3. Return BOTH capabilities:

```java
@Override
public Set<ConnectorCapabilities> getConnectorCapabilities() {
    return EnumSet.of(
        ConnectorCapabilities.REPLICATION_SOURCE,
        ConnectorCapabilities.REPLICATION_DESTINATION
    );
}
```

---

## Next Steps

Once all verification checks pass:
1. Write integration tests for destination operations
2. Test with real data flows (source → your destination)
3. Verify MERGE, APPEND, OVERWRITE modes work correctly
4. Test schema evolution scenarios

---

## Appendix: SQL Generation Helpers

### Build MERGE Statement

```java
private String buildMergeSql(ObjectMetadata stageMetadata, ObjectMetadata targetMetadata) {
    String targetFqn = getFullyQualifiedName(targetMetadata);
    String stageFqn = getFullyQualifiedName(stageMetadata) + "_STAGE";

    // Get primary key fields for join condition
    List<String> pkFields = stageMetadata.getFields().stream()
        .filter(FieldMetadata::isPrimaryKey)
        .map(FieldMetadata::getFormattedName)
        .collect(Collectors.toList());

    if (pkFields.isEmpty()) {
        throw new ConnectorException(
            "No primary key fields defined for MERGE",
            ConnectorException.ErrorType.CONFIGURATION_ERROR
        );
    }

    // Build ON clause
    String onClause = pkFields.stream()
        .map(pk -> "target." + pk + " = source." + pk)
        .collect(Collectors.joining(" AND "));

    // Build UPDATE SET clause (all non-PK fields)
    String updateClause = stageMetadata.getFields().stream()
        .filter(f -> !f.isPrimaryKey())
        .map(f -> f.getFormattedName() + " = source." + f.getFormattedName())
        .collect(Collectors.joining(", "));

    // Build INSERT columns and values
    String insertColumns = stageMetadata.getFields().stream()
        .map(FieldMetadata::getFormattedName)
        .collect(Collectors.joining(", "));

    String insertValues = stageMetadata.getFields().stream()
        .map(f -> "source." + f.getFormattedName())
        .collect(Collectors.joining(", "));

    return String.format(
        "MERGE INTO %s AS target " +
        "USING %s AS source " +
        "ON (%s) " +
        "WHEN MATCHED THEN UPDATE SET %s " +
        "WHEN NOT MATCHED THEN INSERT (%s) VALUES (%s)",
        targetFqn, stageFqn, onClause, updateClause, insertColumns, insertValues
    );
}
```
