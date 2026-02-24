# Phase 8: Activation Targets (API-Based Destinations)

**Objective**: Implement activation connector capabilities for API-based destinations where users map source fields to existing destination objects (no DDL).

**Time Estimate**: 120-180 minutes

**Prerequisite**: Phases 1-6 completed. This phase is for API-based destinations like Salesforce, HubSpot, Marketo where schema is fixed.

**Note**: This is different from Phase 7 (Warehouse Destinations) which creates tables/schemas. Activation connectors write to pre-existing objects via API.

---

## Activation vs Warehouse Destinations

| Aspect | Warehouse (Phase 7) | Activation (Phase 8) |
|--------|---------------------|----------------------|
| **Examples** | Snowflake, BigQuery, Postgres | Salesforce, HubSpot, Marketo |
| **DDL** | Creates tables/schemas | No DDL - fixed schema |
| **stage()** | Upload to cloud storage | Not used |
| **load()** | COPY INTO + MERGE | Direct API upsert/insert |
| **Schema Source** | Generated from source | User maps to existing objects |
| **Field Mapping** | Namespace rules | `activation_target_field` |
| **Merge Keys** | Primary key from schema | `selected_merge_keys` |
| **Error Handling** | Batch success/fail | Per-record success/fail |

---

## Prerequisites

### Essential Reading (MUST read before starting)

| File | What to Learn | Why It Matters |
|------|---------------|----------------|
| `supaflow-core/.../metadata/ObjectMetadata.java` | Activation metadata fields | Where activation config is stored |
| `supaflow-core/.../metadata/FieldMetadata.java` | Field-level activation | Field mapping structure |
| `supaflow-connector-salesforce/.../SalesforceConnector.java` | Reference implementation | Complete activation example |
| `supaflow-connector-salesforce/.../SalesforceDataWriter.java` | Upsert implementation | How to use activation mappings |
| `supaflow-pipeline/.../stages/LoadingStage.java` | Executor flow | How mappings reach connector |
| `supaflow-app/.../ActivationConfigurationStepV2.tsx` | Frontend mapping UI | How users configure activations |

### Activation Quick Checklist (add to every activation connector)

- Set `createable=true` and `updateable=true` on all user-writable fields; set both to `false` **and** `readOnly=true` on system/auto fields (e.g., SFMC `_CustomObjectKey`). Missing flags will cause frontend MERGE validation to reject all fields.
- Ensure `activationTargetField` is populated for every mapped field.
- Mark merge-key candidates (primary keys, external IDs) so UI can auto-select them.
- For child/association objects, set `requiresParentData` and `parentObjectName`, and emit parent ID context (see Phase 5 child/parent reads).
- Keep cleanup idempotent: pre-run cleanup logs at DEBUG; post-run cleanup logs at WARN and uses throwing delete helpers.

### Find and Read Core Classes

```bash
PLATFORM_ROOT="<platform-root>"
REFERENCE_ACTIVATION_CONNECTOR="${REFERENCE_ACTIVATION_CONNECTOR:-salesforce}"

# Activation metadata in ObjectMetadata
grep -n "activationTarget\|activationBehaviour\|selectedMergeKeys" \
  "$PLATFORM_ROOT"/supaflow-core/src/main/java/io/supaflow/core/model/metadata/ObjectMetadata.java

# Field-level activation in FieldMetadata
grep -n "activationTargetField\|activationLookup" \
  "$PLATFORM_ROOT"/supaflow-core/src/main/java/io/supaflow/core/model/metadata/FieldMetadata.java

# Salesforce connector load() method
grep -A 100 "public LoadResponse load(" \
  "$PLATFORM_ROOT"/connectors/supaflow-connector-"$REFERENCE_ACTIVATION_CONNECTOR"/src/main/java/**/*.java

# Salesforce data writer
grep -A 50 "upsertFromLocalFiles" \
  "$PLATFORM_ROOT"/connectors/supaflow-connector-"$REFERENCE_ACTIVATION_CONNECTOR"/src/main/java/**/*.java
```

If no activation reference connector exists locally, keep this phase as the source of truth and enforce checks 16-24 plus activation metadata validation in tests.

### Confirm Understanding

Before proceeding, you MUST be able to answer:

1. What is `activation_target` and what does it contain?
2. What is `activation_target_field` on FieldMetadata?
3. What are `selected_merge_keys` used for?
4. What is `activation_behaviour` and what values can it have?
5. How does `mapToTargetObject()` differ for activations vs warehouses?
6. How are error/success records tracked per-record?

---

## Cancellation in Activation Targets (Required)

- Check cancellation in all write loops (batch upserts, pagination, retry/backoff).
- Never retry `ConnectorException.ErrorType.CANCELLED`.
- Pass the cancellation supplier through to API clients and check it before each API call.

---

## Understanding the Complete Activation Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. FRONTEND (ActivationConfigurationStepV2.tsx)                             │
│                                                                             │
│    User actions:                                                            │
│    ├── Select source table (e.g., "customers" from Snowflake)              │
│    ├── Select destination object (e.g., "Contact" in Salesforce)           │
│    ├── Map source fields → destination fields                              │
│    │   ├── "email" → "Email"                                               │
│    │   ├── "first_name" → "FirstName"                                      │
│    │   └── "external_id" → "External_ID__c" (merge key)                    │
│    └── Select merge key(s) for upsert matching                             │
│                                                                             │
│    Creates metadata:                                                        │
│    ├── activation_target: { object_api_name: "Contact", ... }              │
│    ├── selected_merge_keys: ["External_ID__c"]                             │
│    ├── activation_behaviour: { operation: "UPSERT" }                       │
│    └── Per-field: activation_target_field: "Email", "FirstName", etc.     │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. DATABASE (PostgreSQL - merge_object_selections function)                 │
│                                                                             │
│    Stores in selected_metadata JSONB:                                       │
│    {                                                                        │
│      "activation_target": { ... },                                          │
│      "selected_merge_keys": ["External_ID__c"],                            │
│      "activation_behaviour": { "operation": "UPSERT" },                    │
│      "fields": [                                                            │
│        { "name": "email", "activation_target_field": "Email", ... },       │
│        { "name": "first_name", "activation_target_field": "FirstName" }    │
│      ]                                                                      │
│    }                                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. PIPELINE EXECUTOR (LoadingStage.java)                                    │
│                                                                             │
│    For activations (stagePrefix == null):                                   │
│    ├── Create error/success RecordProcessors                               │
│    ├── Build LoadRequest with:                                             │
│    │   ├── metadataMapping (contains activation metadata)                  │
│    │   ├── localDataPath (CSV files from ingestion)                        │
│    │   ├── errorRecordProcessor                                            │
│    │   └── successRecordProcessor                                          │
│    └── Call connector.load(loadRequest)                                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 4. CONNECTOR load() (SalesforceConnector.java)                              │
│                                                                             │
│    Extract activation metadata:                                             │
│    ├── targetMetadata = mapping.getMappedMergedSourceMetadata()            │
│    ├── destinationObject = targetMetadata.getActivationTarget()            │
│    ├── mergeKeys = targetMetadata.getSelectedMergeKeys()                   │
│    └── behaviour = targetMetadata.getActivationBehaviour()                 │
│                                                                             │
│    Delegate to DataWriter:                                                  │
│    └── dataWriter.upsertFromLocalFiles(dataPath, mapping, ...)             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 5. DATA WRITER (SalesforceDataWriter.java)                                  │
│                                                                             │
│    For each CSV file:                                                       │
│    ├── Read records from CSV                                               │
│    ├── For each record, convert to API format:                             │
│    │   ├── Get field.getActivationTargetField() → destination field name  │
│    │   ├── Convert value to destination type                               │
│    │   └── Build API object (SObject for Salesforce)                       │
│    ├── Batch records (e.g., 200 per API call)                              │
│    ├── Call API upsert with external ID field                              │
│    └── For each result:                                                     │
│        ├── Success → successRecordProcessor.processRecord(record + ID)     │
│        └── Failure → errorRecordProcessor.processRecord(record + error)    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Activation Metadata Fields

### ObjectMetadata Activation Fields

```java
// From supaflow-core/src/main/java/io/supaflow/core/model/metadata/ObjectMetadata.java

/**
 * Target destination object for activation pipelines.
 * Contains information about the Salesforce/HubSpot/etc. object to write to.
 */
private Map<String, Object> activationTarget;
// Example:
// {
//   "connector_id": "uuid",
//   "object_api_name": "Contact",
//   "name": "Contact",
//   "catalog": null,
//   "schema": null,
//   "fully_qualified_name": "Contact",
//   "formatted_name": "Contact",
//   "formatted_fully_qualified_name": "Contact"
// }

/**
 * Merge keys for upsert operations.
 * These are DESTINATION field names used to match existing records.
 */
private List<String> selectedMergeKeys;
// Example: ["External_ID__c", "Email"]

/**
 * Activation behavior configuration.
 * Controls insert/update/upsert mode and other options.
 */
private Map<String, Object> activationBehaviour;
// Example:
// {
//   "operation": "UPSERT",  // or "INSERT", "UPDATE"
//   "insert_nulls": true,
//   "trim_whitespace": true
// }
```

### FieldMetadata Activation Fields

```java
// From supaflow-core/src/main/java/io/supaflow/core/model/metadata/FieldMetadata.java

/**
 * Destination field name for activation.
 * Maps this source field to the target API field.
 */
private String activationTargetField;
// Example: Source field "email" maps to Salesforce field "Email"

/**
 * Writability flags (REQUIRED for activation connectors):
 * - createable=true and updateable=true for user-writable fields
 * - createable=false and updateable=false for system/auto fields (also set readOnly=true)
 *
 * Frontend validation and merge-key checks rely on these being populated.
 * Missing flags will cause all fields to be rejected for MERGE (seen in SFMC DEs).
 */
private Boolean createable;
private Boolean updateable;

/**
 * Lookup relationship configuration for reference fields.
 * Used when the destination field is a relationship (e.g., AccountId).
 */
private Map<String, Object> activationLookup;
// Example:
// {
//   "reference_to": ["Account"],
//   "relationship_name": "Account",
//   "relationship_api_name": "Account",
//   "parent_match_field": "External_ID__c",
//   "parent_object_api_name": "Account"
// }
```

---

## Step 1: Implement mapToTargetObject() for Activations

For activation connectors, `mapToTargetObject()` is a **pass-through** that preserves activation metadata. Unlike warehouse connectors, we don't transform the schema.

```java
@Override
public ObjectMetadata mapToTargetObject(ObjectMetadata sourceObj,
                                        NamespaceRules namespaceRules,
                                        ObjectMetadata existingMappedObj) throws ConnectorException {
    if (sourceObj == null) {
        return null;
    }

    // Log source object's activation attributes before mapping
    log.debug("mapToTargetObject - sourceObj name: {}, activation_target: {}, " +
              "selected_merge_keys: {}, activation_behaviour: {}",
            sourceObj.getName(),
            sourceObj.getActivationTarget(),
            sourceObj.getSelectedMergeKeys(),
            sourceObj.getActivationBehaviour());

    // For activation pipelines, defer destination remapping until load time
    // so we can continue writing CSVs with the original source column names.
    // Return a defensive copy to preserve activation metadata.
    ObjectMetadata mappedObj = new ObjectMetadata(sourceObj);

    // Verify critical attributes are preserved
    if (sourceObj.getActivationTarget() != null && mappedObj.getActivationTarget() == null) {
        log.error("CRITICAL: activation_target was lost during copy constructor!");
    }

    // Verify field mappings are preserved
    if (sourceObj.getFields() != null && mappedObj.getFields() != null) {
        for (int i = 0; i < sourceObj.getFields().size(); i++) {
            var sourceField = sourceObj.getFields().get(i);
            var mappedField = mappedObj.getFields().get(i);
            if (sourceField.getActivationTargetField() != null &&
                mappedField.getActivationTargetField() == null) {
                log.error("CRITICAL: Field {} lost activation_target_field during copy!",
                        sourceField.getName());
            }
        }
    }

    return mappedObj;
}
```

---

## Step 2: Implement load() for Activations

```java
@Override
public LoadResponse load(LoadRequest request) throws ConnectorException {
    if (request == null) {
        throw new ConnectorException("LoadRequest cannot be null",
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
    }

    // Activation connectors do NOT use staging
    if (request.getStageLocation() != null) {
        throw new ConnectorException("Stage-based loading is not supported for " + getName(),
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
    }

    // Handle zero rows case
    if (request.isZeroRows()) {
        if (request.getCallback() != null) {
            request.getCallback().update(new CallbackStatusDto(0L, 0L, CallbackStatus.ENDED));
        }
        return LoadResponse.success("No data to load");
    }

    // Require local data path
    String localDataPath = request.getLocalDataPath();
    if (localDataPath == null || localDataPath.isEmpty()) {
        throw new ConnectorException("Local data path is required for activation loads",
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
    }

    // Get metadata mapping
    PipelineMetadataMappingAndSourceMetadataCatalog mapping = request.getMetadataMapping();
    if (mapping == null) {
        throw new ConnectorException("Metadata mapping is required for activation load",
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
    }

    // Get mapped metadata with activation fields
    ObjectMetadata targetMetadata = mapping.getMappedMergedSourceMetadata();
    if (targetMetadata == null) {
        throw new ConnectorException("Mapped metadata is required for activation load",
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
    }

    // Extract activation configuration
    String destinationObjectName = resolveDestinationObjectName(targetMetadata);
    if (destinationObjectName == null || destinationObjectName.isBlank()) {
        throw new ConnectorException("Unable to resolve destination object name",
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
    }

    List<String> mergeKeys = targetMetadata.getSelectedMergeKeys();
    String externalIdField = (mergeKeys != null && !mergeKeys.isEmpty())
        ? mergeKeys.get(0)
        : getDefaultMergeKey();  // e.g., "Id" for Salesforce

    // Apply activation behaviour settings
    applyActivationBehaviour(targetMetadata.getActivationBehaviour());

    // Create data writer with API client
    try {
        DataWriter writer = createDataWriter();

        // Set error and success record processors if provided
        if (request.getErrorRecordProcessor() != null) {
            writer.setErrorRecordProcessor(request.getErrorRecordProcessor());
            log.debug("[{}] Error record processor configured", getName());
        }
        if (request.getSuccessRecordProcessor() != null) {
            writer.setSuccessRecordProcessor(request.getSuccessRecordProcessor());
            log.debug("[{}] Success record processor configured", getName());
        }

        // Execute upsert from local files
        CsvFileFormat csvFormat = request.getFileFormat() instanceof CsvFileFormat
                ? (CsvFileFormat) request.getFileFormat()
                : new CsvFileFormat();

        Path dataDir = Paths.get(localDataPath);
        BatchResult result = writer.upsertFromLocalFiles(
                dataDir,
                csvFormat,
                mapping,
                destinationObjectName,
                externalIdField,
                request.getCallback()
        );

        return LoadResponse.withCounts(result.successCount, result.errorCount);

    } catch (ConnectorException e) {
        throw e;
    } catch (Exception e) {
        log.error("Failed to load data: {}", e.getMessage(), e);
        throw new ConnectorException(
            "Failed to load data: " + e.getMessage(),
            e,
            ConnectorException.ErrorType.API_ERROR
        );
    }
}

/**
 * Resolve destination object name from activation_target.
 */
private String resolveDestinationObjectName(ObjectMetadata mappedMetadata) {
    if (mappedMetadata == null) {
        return null;
    }

    Map<String, Object> activationTarget = mappedMetadata.getActivationTarget();
    if (activationTarget == null || activationTarget.isEmpty()) {
        return null;
    }

    // Try formatted_fully_qualified_name first
    Object formattedFqn = activationTarget.get("formatted_fully_qualified_name");
    if (formattedFqn instanceof String formatted && !formatted.isBlank()) {
        return formatted;
    }

    // Fall back to fully_qualified_name
    Object fqn = activationTarget.get("fully_qualified_name");
    if (fqn instanceof String full && !full.isBlank()) {
        return full;
    }

    // Fall back to object_api_name
    Object apiName = activationTarget.get("object_api_name");
    if (apiName instanceof String api && !api.isBlank()) {
        return api;
    }

    // Fall back to name
    Object name = activationTarget.get("name");
    if (name instanceof String n && !n.isBlank()) {
        return n;
    }

    return null;
}

/**
 * Apply activation behaviour settings.
 */
private void applyActivationBehaviour(Map<String, Object> behaviour) {
    if (behaviour == null) {
        return;
    }

    // Extract common settings
    if (behaviour.containsKey("insert_nulls")) {
        this.insertNulls = Boolean.TRUE.equals(behaviour.get("insert_nulls"));
    }
    if (behaviour.containsKey("trim_whitespace")) {
        this.trimWhitespace = Boolean.TRUE.equals(behaviour.get("trim_whitespace"));
    }
    // Add connector-specific behaviour settings
}
```

---

## Step 3: Implement DataWriter for Activations

Create a helper class to handle the actual API writes:

```java
public class ActivationDataWriter {

    private final ApiClient apiClient;
    private final int batchSize;
    private RecordProcessor errorRecordProcessor;
    private RecordProcessor successRecordProcessor;

    // Settings from activation_behaviour
    private boolean insertNulls = true;
    private boolean trimWhitespace = false;

    public ActivationDataWriter(ApiClient apiClient, int batchSize) {
        this.apiClient = apiClient;
        this.batchSize = batchSize;
    }

    public BatchResult upsertFromLocalFiles(
            Path dataPath,
            CsvFileFormat fileFormat,
            PipelineMetadataMappingAndSourceMetadataCatalog metadataMapping,
            String destinationObjectName,
            String externalIdField,
            ConnectorCallback callback) throws ConnectorException {

        // Get metadata with activation mappings
        ObjectMetadata mappedMetadata = metadataMapping.getMappedMergedSourceMetadata();

        // Get selected fields with activation_target_field mappings
        List<FieldMetadata> selectedFields = mappedMetadata.getFields().stream()
                .filter(f -> Boolean.TRUE.equals(f.getSelected()))
                .filter(f -> f.getActivationTargetField() != null)
                .collect(Collectors.toList());

        if (selectedFields.isEmpty()) {
            throw new ConnectorException("No mapped fields found for activation load",
                    ConnectorException.ErrorType.CONFIGURATION_ERROR);
        }

        // Build field map: source field name → field metadata
        Map<String, FieldMetadata> fieldMap = selectedFields.stream()
                .collect(Collectors.toMap(
                        FieldMetadata::getName,
                        f -> f,
                        (a, b) -> a,
                        LinkedHashMap::new));

        // Get destination metadata for field validation (if available)
        ObjectMetadata destMetadata = metadataMapping.getActualDestinationMetadata();
        if (destMetadata != null) {
            fieldMap = applyFieldValidation(fieldMap, destMetadata, externalIdField);
        }

        // List CSV files
        List<Path> files = listCsvFiles(dataPath);
        if (files.isEmpty()) {
            callback.update(new CallbackStatusDto(0L, 0L, CallbackStatus.ENDED));
            return new BatchResult(0L, 0L);
        }

        long successCount = 0L;
        long errorCount = 0L;

        // Process each file
        for (Path file : files) {
            log.info("[Activation] Processing file {}", file);

            try (CSVReadingRecordProcessor reader = new CSVReadingRecordProcessor(
                    Files.newInputStream(file), fileFormat)) {

                List<Map<String, Object>> batch = new ArrayList<>(batchSize);
                Map<String, Object> record;

                while ((record = reader.getRecord()) != null) {
                    batch.add(record);

                    if (batch.size() >= batchSize) {
                        BatchResult batchResult = processBatch(
                                batch, destinationObjectName, externalIdField, fieldMap);
                        successCount += batchResult.successCount;
                        errorCount += batchResult.errorCount;
                        batch.clear();

                        // Update callback with progress
                        callback.update(new CallbackStatusDto(
                                successCount + errorCount,  // total processed
                                successCount,               // output row count
                                errorCount,                 // error count
                                CallbackStatus.RUNNING
                        ));
                    }
                }

                // Process remaining records
                if (!batch.isEmpty()) {
                    BatchResult batchResult = processBatch(
                            batch, destinationObjectName, externalIdField, fieldMap);
                    successCount += batchResult.successCount;
                    errorCount += batchResult.errorCount;
                }
            }
        }

        // Final callback update
        callback.update(new CallbackStatusDto(
                successCount + errorCount,
                successCount,
                errorCount,
                CallbackStatus.ENDED
        ));

        return new BatchResult(successCount, errorCount);
    }

    /**
     * Process a batch of records via API.
     */
    private BatchResult processBatch(
            List<Map<String, Object>> batch,
            String objectName,
            String externalIdField,
            Map<String, FieldMetadata> fieldMap) throws ConnectorException {

        long successCount = 0;
        long errorCount = 0;

        // Convert records to API format
        List<ApiObject> apiObjects = new ArrayList<>();
        for (Map<String, Object> record : batch) {
            ApiObject obj = convertToApiObject(record, objectName, fieldMap);
            apiObjects.add(obj);
        }

        // Call API upsert
        List<ApiResult> results = apiClient.upsert(objectName, externalIdField, apiObjects);

        // Process results
        for (int i = 0; i < results.size(); i++) {
            ApiResult result = results.get(i);
            Map<String, Object> sourceRecord = batch.get(i);

            if (result.isSuccess()) {
                successCount++;
                if (successRecordProcessor != null) {
                    // Add returned ID to record
                    Map<String, Object> successRecord = new LinkedHashMap<>();
                    successRecord.put("_ID", result.getId());
                    successRecord.putAll(extractMappedFields(sourceRecord, fieldMap));
                    successRecordProcessor.processRecord(successRecord);
                }
            } else {
                errorCount++;
                if (errorRecordProcessor != null) {
                    // Add error message to record
                    Map<String, Object> errorRecord = new LinkedHashMap<>(
                            extractMappedFields(sourceRecord, fieldMap));
                    errorRecord.put("_ERROR", result.getErrorMessage());
                    errorRecordProcessor.processRecord(errorRecord);
                }
            }
        }

        return new BatchResult(successCount, errorCount);
    }

    /**
     * Convert source record to API object using activation_target_field mappings.
     */
    private ApiObject convertToApiObject(
            Map<String, Object> record,
            String objectName,
            Map<String, FieldMetadata> fieldMap) throws ConnectorException {

        ApiObject obj = new ApiObject(objectName);
        List<String> fieldsToNull = new ArrayList<>();

        for (Map.Entry<String, Object> entry : record.entrySet()) {
            String sourceFieldName = entry.getKey();
            Object rawValue = entry.getValue();

            FieldMetadata metadata = fieldMap.get(sourceFieldName);
            if (metadata == null) {
                continue;  // Skip fields without activation mapping
            }

            // Get destination field name from activation_target_field
            String targetFieldName = metadata.getActivationTargetField();
            if (targetFieldName == null || targetFieldName.isBlank()) {
                throw new ConnectorException(
                        String.format("Field '%s' is missing activation_target_field", sourceFieldName),
                        ConnectorException.ErrorType.CONFIGURATION_ERROR);
            }

            // Handle lookup relationships
            if (metadata.getActivationLookup() != null) {
                handleLookupField(obj, metadata, rawValue);
                continue;
            }

            // Handle null values
            if (rawValue == null || rawValue.toString().isEmpty()) {
                if (insertNulls) {
                    fieldsToNull.add(targetFieldName);
                }
                continue;
            }

            // Convert and set value
            String stringValue = rawValue.toString();
            if (trimWhitespace) {
                stringValue = stringValue.trim();
            }
            Object convertedValue = convertValue(stringValue, metadata);
            obj.setField(targetFieldName, convertedValue);
        }

        if (!fieldsToNull.isEmpty()) {
            obj.setFieldsToNull(fieldsToNull);
        }

        return obj;
    }

    /**
     * Handle lookup/relationship fields.
     */
    private void handleLookupField(ApiObject obj, FieldMetadata metadata, Object rawValue) {
        Map<String, Object> lookup = metadata.getActivationLookup();
        if (lookup == null) return;

        String relationshipName = (String) lookup.get("relationship_api_name");
        String parentMatchField = (String) lookup.get("parent_match_field");
        String parentObject = (String) lookup.get("parent_object_api_name");

        if (relationshipName == null || parentMatchField == null || parentObject == null) {
            return;
        }

        if (rawValue == null || rawValue.toString().isEmpty()) {
            if (insertNulls) {
                obj.setField(relationshipName, null);
            }
            return;
        }

        // Create parent reference object
        ApiObject parentRef = new ApiObject(parentObject);
        parentRef.setField(parentMatchField, rawValue.toString());
        obj.setField(relationshipName, parentRef);
    }

    public static class BatchResult {
        public final long successCount;
        public final long errorCount;

        public BatchResult(long successCount, long errorCount) {
            this.successCount = successCount;
            this.errorCount = errorCount;
        }
    }
}
```

---

## Step 4: Implement stage() (Not Used)

For activation connectors, stage() should throw an exception or return a no-op:

```java
@Override
public StageResponse stage(StageRequest request) throws ConnectorException {
    throw new UnsupportedOperationException(
        "Stage method not supported for " + getName() + ". " +
        "This connector writes directly to the destination API.");
}
```

---

## Step 5: Configure Connector Capabilities

```java
@Override
public Set<ConnectorCapabilities> getConnectorCapabilities() {
    return EnumSet.of(
        ConnectorCapabilities.REPLICATION_SOURCE,      // Can read from this connector
        ConnectorCapabilities.REPLICATION_DESTINATION  // Can write to this connector
    );
}

@Override
public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
    return ConnectorCapabilitiesConfigBuilder.builder()
        // Use API connector preset
        .asAPIConnector()

        // Load modes (activation typically only supports MERGE = upsert)
        .loadModes(LoadMode.MERGE, LoadMode.APPEND)
        .defaultLoadMode(LoadMode.MERGE)

        // No staging for API destinations
        .supportsStaging(false)
        .requiresStaging(false)
        .requiresExplicitLoadStep(false)

        // API connectors typically can't auto-create schema
        .canAutoCreateSchema(false)

        // Rate limiting is critical for APIs
        .supportsRateLimit(true)

        // Checksum validation options
        .checksumValidationLevels(ChecksumValidationLevel.NONE, ChecksumValidationLevel.ROW_COUNT)
        .defaultChecksumLevel(ChecksumValidationLevel.NONE)

        .build();
}
```

---

## Error and Success Record Handling

The executor creates error/success processors and passes them to `load()`:

```java
// From LoadingStage.java - how executor creates processors

RecordProcessor[] processors = createErrorAndSuccessProcessors(
        mapped, ctx.jobDetail, csv, chunkSize, bufferSize);
RecordProcessor errorProcessor = processors[0];
RecordProcessor successProcessor = processors[1];

// Pass to connector
ctx.destinationConnector.load(
    LoadRequest.builder()
        .metadataMapping(filteredMapping)
        .localDataPath(dataPath)
        .syncTime(syncTime)                        // Required: cutoffTime from metadata
        .syncId(syncId)                            // Required: job ID for tracking
        .errorRecordProcessor(errorProcessor)      // For failed records
        .successRecordProcessor(successProcessor)  // For successful records
        .build()
);
```

### Error File Format

```csv
email,first_name,external_id,_ERROR
bad@email,John,EXT001,"INVALID_EMAIL: Email format is invalid"
duplicate@test.com,Jane,EXT002,"DUPLICATE_VALUE: External_ID__c already exists"
```

### Success File Format

```csv
_ID,email,first_name,external_id
003xx000001ABCD,good@email.com,Bob,EXT003
003xx000001EFGH,another@test.com,Alice,EXT004
```

---

## Reference: Salesforce Connector Implementation

### Key Files

| File | Purpose |
|------|---------|
| `SalesforceConnector.java:970-1082` | `load()` method for activations |
| `SalesforceConnector.java:1216-1285` | `mapToTargetObject()` pass-through |
| `SalesforceDataWriter.java:134-350` | `upsertFromLocalFiles()` implementation |
| `SalesforceDataWriter.java:458-513` | `convertToSObject()` with activation_target_field |
| `SalesforceFieldValidator.java` | Field validation for createable/updateable |

### Key Patterns from Salesforce

1. **Resolve destination object name**:
```java
String destinationObjectName = resolveDestinationObjectName(targetMetadata);
// Extracts from activation_target.formatted_fully_qualified_name or fallbacks
```

2. **Get merge key**:
```java
List<String> mergeKeys = targetMetadata.getSelectedMergeKeys();
String externalIdField = (mergeKeys != null && !mergeKeys.isEmpty()) ? mergeKeys.get(0) : "Id";
```

3. **Apply activation behaviour**:
```java
applyActivationBehaviour(writer, targetMetadata.getActivationBehaviour());
// Sets insertNulls, trimWhitespace, duplicateRuleSettings, etc.
```

4. **Map fields using activation_target_field**:
```java
String targetFieldName = metadata.getActivationTargetField();
sObject.setField(targetFieldName, convertedValue);
```

---

## Gate Verification

### Manual Checklist

| Check | Verification |
|-------|--------------|
| ☐ mapToTargetObject() preserves activation metadata | Code review |
| ☐ load() extracts activation_target | Code review |
| ☐ load() uses selected_merge_keys for upsert | Code review |
| ☐ load() respects activation_behaviour | Code review |
| ☐ DataWriter uses activation_target_field for mapping | Code review |
| ☐ Error processor receives failed records | Test |
| ☐ Success processor receives successful records + IDs | Test |
| ☐ stage() throws UnsupportedOperationException | Code review |
| ☐ getCapabilitiesConfig() uses .asAPIConnector() | Code review |
| ☐ Rate limiting is handled | Code review |

### Verification Commands

```bash
# Check for activation_target handling
grep -n "getActivationTarget\|activation_target" src/main/java/**/*.java

# Check for field mapping
grep -n "getActivationTargetField\|activation_target_field" src/main/java/**/*.java

# Check for merge keys
grep -n "getSelectedMergeKeys\|selected_merge_keys" src/main/java/**/*.java

# Check for error/success processors
grep -n "ErrorRecordProcessor\|SuccessRecordProcessor" src/main/java/**/*.java
```

---

## Common Mistakes to Avoid

| Mistake | Why It's Wrong | Correct Approach |
|---------|----------------|------------------|
| **Using namespace rules for field mapping** | Activation uses explicit field mappings | Use `activation_target_field` |
| **Calling stage() before load()** | Activations write directly via API | Only use `load()` with `localDataPath` |
| **Not handling per-record errors** | Users need to know which records failed | Use error/success processors |
| **Ignoring activation_behaviour** | User settings like insertNulls ignored | Apply all behaviour settings |
| **Ignoring rate limits** | API throttling causes failures | Implement rate limiting/backoff |
| **Not validating destination fields** | Read-only fields cause errors | Validate createable/updateable |
| **Transforming schema in mapToTargetObject()** | Breaks activation field mappings | Pass-through only |

---

## Next Steps

After implementing activation connector:
1. Test with real activation pipeline (source → your destination)
2. Verify error/success files are correctly generated
3. Test with various field types (text, number, date, lookup)
4. Test rate limiting and batch sizes
5. Test with partial failures (some records succeed, some fail)
