# Phase 4: Schema Discovery

**Objective**: Implement schema discovery with proper ObjectMetadata, FieldMetadata, primary keys, and cursor fields.

**Time Estimate**: 60-90 minutes

**Prerequisite**: Phase 3 completed and verified.

---

## Prerequisites

### Essential Reading (MUST read before starting)

**CRITICAL**: You MUST read these core classes before writing ANY schema code. Do not skip this step.

| File | What to Learn | Why It Matters |
|------|---------------|----------------|
| `supaflow-core/.../model/metadata/ObjectMetadata.java` | Full ObjectMetadata class | Every field you can set |
| `supaflow-core/.../model/metadata/FieldMetadata.java` | Full FieldMetadata class | **CRITICAL: originalDataType, canonicalType** |
| `supaflow-core/.../enums/CanonicalType.java` | Available type enum | Valid type mappings |
| `supaflow-connector-sdk/.../model/SchemaRequest.java` | Schema request inputs | Filtering/level controls |
| `supaflow-connector-sdk/.../model/SchemaResponse.java` | Schema response wrapper | How to return objects |
| `supaflow-connector-sdk/.../schema/SchemaGenerator.java` | Inference pipeline facade | Sample + infer + map workflow |
| `supaflow-connector-sdk/.../schema/SchemaGenerationRequest.java` | Inference request model | Required request contract |
| `supaflow-connector-sdk/.../schema/SchemaInferenceResult.java` | Result + diagnostics | Access inferred object and confidence |
| `supaflow-connector-sdk/.../schema/inference/RecordSupplier.java` | Sample record contract | Connector-specific sampling implementation |
| Reference connector schema(request) | Real examples | See complete implementations |

### Find and Read Core Classes

```bash
PLATFORM_ROOT="<platform-root>"
REFERENCE_SOURCE_CONNECTOR="${REFERENCE_SOURCE_CONNECTOR:-hubspot}"

# MUST read these files before proceeding
find "$PLATFORM_ROOT" -name "ObjectMetadata.java" -path "*/supaflow-core/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "FieldMetadata.java" -path "*/supaflow-core/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "CanonicalType.java" -path "*/supaflow-core/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "SchemaRequest.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "SchemaResponse.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "SchemaGenerator.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "SchemaGenerationRequest.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "SchemaInferenceResult.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "RecordSupplier.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;

# Read at least one reference connector's schema method
grep -A 100 "SchemaResponse schema" \
  "$PLATFORM_ROOT"/connectors/supaflow-connector-"$REFERENCE_SOURCE_CONNECTOR"/src/main/java/**/*.java
grep -A 160 "SchemaGenerator\\|SchemaGenerationRequest\\|RecordSupplier" \
  "$PLATFORM_ROOT"/connectors/supaflow-connector-"$REFERENCE_SOURCE_CONNECTOR"/src/main/java/**/*.java
```

If no suitable reference connector exists in your repo, use this phase document as the baseline and enforce the anti-pattern checks before moving on.

### Confirm Understanding

Before proceeding, you MUST be able to answer:

1. What fields does ObjectMetadata have? (name, fullyQualifiedName, type, objectType, fields, description, customAttributes, incrementalStrategy, identityStrategy, etc.)
2. What fields does FieldMetadata have? (name, label, canonicalType, originalDataType, sourcePrimaryKey, sourceCursorField, capabilities, nillable, precision/scale, etc.)
3. **CRITICAL**: What is `originalDataType` and why must it ALWAYS be set?
4. What CanonicalTypes are available? (STRING, LONG, DOUBLE, BOOLEAN, INSTANT, LOCALDATE, JSON, etc.)
5. How do you mark a connector-discovered source primary key?
6. How do you mark a connector-discovered source cursor field?
7. What is `setCursorFieldLocked(true)` for?
8. When should you use `SchemaGenerator` instead of manual per-field type mapping?
9. What diagnostics are available in `SchemaInferenceResult` and how can they drive type-correction logs?

---

## SchemaGenerator Pattern (Required for Sample-Based Discovery)

If your connector infers types from sampled records, use the SDK inference pipeline:

`RecordSupplier -> SchemaGenerator.generate(SchemaGenerationRequest) -> SchemaInferenceResult`

```java
SchemaGenerator generator = SchemaGenerator.create();

RecordSupplier supplier = createRecordSupplier(sampleData);
SchemaGenerationRequest request = SchemaGenerationRequest.builder(objectName, supplier)
    .connectorName("{name}")
    .mappingConfig(MappingConfig.withPrimaryKeys(primaryKeyFields.toArray(new String[0])))
    .build();

SchemaInferenceResult result = generator.generate(request);
ObjectMetadata inferred = result.getObject();

if (result.getDiagnostics().hasWarnings()) {
    log.warn("Schema inference warnings for {}: {}", objectName, result.getDiagnostics().getWarnings());
}
```

Use Oracle TM as the reference implementation for:
- sample-first inference
- metadata reconciliation/corrections
- diagnostics-aware logging

For metadata-driven sources (OData `$metadata`, OpenAPI schemas, JDBC catalogs, etc.), build `ObjectMetadata` directly from the declared schema and skip `SchemaGenerator`; do not infer types from samples when the source publishes authoritative metadata.

---

## Cancellation in Schema Discovery (Required)

- Check cancellation in all schema discovery loops (schemas, tables, fields, pagination).
- For JDBC connectors, register/clear statements around every query:
  - `registerCurrentStatement(conn, stmt)` before `executeQuery()`
  - `clearCurrentStatement()` in a `finally` block
- If iterating a `ResultSet`, call `checkCancellation(...)` (or `checkCancellationPublic(...)`) inside the loop.

```java
// JDBC schema discovery with cancellation
try (PreparedStatement stmt = conn.prepareStatement(query)) {
    registerCurrentStatement(conn, stmt);
    try (ResultSet rs = stmt.executeQuery()) {
        while (rs.next()) {
            checkCancellation("schema discovery");
            // process row
        }
    } finally {
        clearCurrentStatement();
    }
}
```

---

## Understanding ObjectMetadata

ObjectMetadata represents a table/object that can be synced:

```java
ObjectMetadata object = new ObjectMetadata();

// Required fields
object.setName("journey");                    // API/internal name (lowercase, underscore)
object.setFullyQualifiedName("journey");      // Stable source object identifier
object.setType("TABLE");                      // Required; source_metadata_catalog.object_type is NOT NULL
object.setFields(fieldList);                  // List<FieldMetadata>
object.setIncrementalStrategy(IncrementalStrategy.COLUMN_CURSOR); // or UNSUPPORTED / CONNECTOR_MANAGED
object.setIdentityStrategy(IdentityStrategy.SOURCE_KEY);          // or ROW_HASH when no stable source key exists

// Optional but recommended
object.setObjectType(ObjectType.PRIMARY);      // PRIMARY, ASSOCIATION, HISTORY, METADATA
object.setDescription("Marketing journeys");  // Help text
object.setCursorFieldLocked(true);            // Cursor field identification has been completed

// Custom attributes (for storing metadata needed during read)
object.putCustomAttribute("api_endpoint", "/interaction/v1/interactions");
object.putCustomAttribute("api_type", "REST");  // or "SOAP"
```

---

## Understanding FieldMetadata

**CRITICAL**: Every field MUST have `originalDataType` set. This is the #1 mistake agents make.

```java
FieldMetadata field = new FieldMetadata();

// ================================================================
// REQUIRED FIELDS - Must set ALL of these
// ================================================================

field.setName("modified_date");               // Field name (lowercase, underscore)
field.setCanonicalType(CanonicalType.INSTANT); // Target type for destination
field.setOriginalDataType("DateTime");         // CRITICAL: Source system's type name

// ================================================================
// SOURCE PRIMARY KEY - Connector-discovered default business key
// ================================================================

field.setSourcePrimaryKey(true);               // Source exposes this as a stable business key
field.setPrimaryKeyCapable(true);              // This field can be selected as a primary key

// ================================================================
// SOURCE CURSOR FIELD - For incremental sync
// ================================================================

field.setSourceCursorField(true);              // Source supports filtering on this
field.setCursorCapable(true);                  // This field can be selected as a cursor
field.setFilterable(true);                     // Can filter API by this field

// ================================================================
// OPTIONAL FIELDS
// ================================================================

field.setLabel("Modified Date");               // Human-readable label
field.setOriginalName("modifiedDate");         // Source/API field name when different from normalized name
field.setDescription("Last modification time"); // Help text
field.setNillable(true);                       // Can be null?
```

### Required ObjectMetadata and FieldMetadata Checklist

Every discovered object must set:
- `name`
- `fullyQualifiedName`
- `type` (usually `"TABLE"`)
- `fields`
- `incrementalStrategy` (`COLUMN_CURSOR`, `CONNECTOR_MANAGED`, or `UNSUPPORTED`; do not use legacy `NONE`)
- `identityStrategy` (`SOURCE_KEY` when the source declares a key, otherwise `ROW_HASH` when row identity is derived)

Recommended object field:
- `objectType` (`ObjectType.PRIMARY` for normal source objects)

Every discovered field must set:
- `name`
- `canonicalType`
- `originalDataType`
- `primaryKeyCapable`
- `cursorCapable`
- For `BIGDECIMAL`, set precision in `1..38` and scale in `0..min(37, precision)`
- Source flags are sparse booleans: set `sourcePrimaryKey` / `sourceCursorField` only for true defaults; leave them unset instead of setting `false`

Recommended field value:
- `originalName` when the source/API field name differs from the normalized Supaflow field name

### Why originalDataType is CRITICAL

`originalDataType` stores the source system's native type name. It's used for:

1. **Schema evolution tracking** - Detecting when source types change
2. **Type conversion logging** - Documenting what conversion happened
3. **Debugging** - Understanding where data came from
4. **Destination DDL** - Some destinations use original type hints

**Examples**:

| Source | originalDataType | canonicalType |
|--------|-----------------|---------------|
| SFMC Text | `"Text"` | STRING |
| SFMC Number | `"Number"` | LONG |
| SFMC Date | `"Date"` | INSTANT |
| PostgreSQL varchar(255) | `"varchar"` | STRING |
| Airtable singleLineText | `"singleLineText"` | STRING |
| JSON string field | `"string"` | STRING |

---

## CanonicalType Reference

```java
public enum CanonicalType {
    JSON,           // Complex/nested structures
    STRING,         // Text data
    DOUBLE,         // 64-bit floating point
    FLOAT,          // 32-bit floating point
    BIGDECIMAL,     // Arbitrary precision decimals (financial data)
    LONG,           // 64-bit integers
    INT,            // 32-bit integers
    SHORT,          // 16-bit integers
    BOOLEAN,        // True/false
    INSTANT,        // Timestamp with timezone (ISO 8601)
    LOCALDATETIME,  // Timestamp without timezone
    LOCALDATE,      // Date without time (YYYY-MM-DD)
    BINARY,         // Binary data (blobs, files)
    XML             // XML documents
}
```

### Type Mapping Guidelines

| Source Type Pattern | CanonicalType | Notes |
|--------------------|---------------|-------|
| string, text, varchar, char | STRING | |
| smallint, tinyint | SHORT | 16-bit integers |
| int, integer | INT | 32-bit integers |
| bigint, number (no decimals) | LONG | 64-bit integers |
| float, real | FLOAT | 32-bit floating point |
| double, double precision | DOUBLE | 64-bit floating point |
| decimal, numeric, money | BIGDECIMAL | Arbitrary precision |
| boolean, bool, bit | BOOLEAN | |
| datetime, timestamp with tz | INSTANT | With timezone |
| datetime2, timestamp without tz | LOCALDATETIME | Without timezone |
| date | LOCALDATE | Date only |
| json, object, array, map | JSON | Complex structures |
| binary, blob, varbinary, bytea | BINARY | |
| xml | XML | |

---

## Step 1: Create FieldMetadata Builder Helper

Create a helper to ensure all required fields are set:

```java
import io.supaflow.core.model.metadata.FieldCapabilityUtil;

/**
 * Helper to create FieldMetadata with all required fields.
 * Ensures originalDataType is ALWAYS set.
 */
private FieldMetadata createField(
        String name,
        String label,
        CanonicalType canonicalType,
        String originalDataType,  // REQUIRED - source system type
        boolean isSourcePrimaryKey) {

    FieldMetadata field = new FieldMetadata();

    // Required
    field.setName(name);
    field.setCanonicalType(canonicalType);
    field.setOriginalDataType(originalDataType);  // CRITICAL - MUST set

    // Optional but recommended
    field.setLabel(label != null ? label : name);
    if (isSourcePrimaryKey) {
        field.setSourcePrimaryKey(true);
    }
    field.setPrimaryKeyCapable(FieldCapabilityUtil.isPrimaryKeyCapable(canonicalType));
    field.setCursorCapable(FieldCapabilityUtil.isCursorCapable(canonicalType));
    field.setNillable(!isSourcePrimaryKey);  // PKs are not nullable
    if (canonicalType == CanonicalType.BIGDECIMAL) {
        field.setPrecision(38);
        field.setScale(18);
    }

    return field;
}

// Convenience overload for non-PK fields
private FieldMetadata createField(
        String name,
        CanonicalType canonicalType,
        String originalDataType) {
    return createField(name, null, canonicalType, originalDataType, false);
}
```

---

## Step 2: Implement Source Key and Identity Identification

Every object MUST declare an `identityStrategy`. Mark `sourcePrimaryKey` fields only when the source exposes a stable key. If the source does not expose a stable key, use `IdentityStrategy.ROW_HASH` instead of inventing a fragile primary key.

```java
/**
 * Identify and mark source primary key fields, then set object identity strategy.
 *
 * Strategy:
 * 1. Prefer primary keys declared by the source schema (OData <Key>, JDBC PK, OpenAPI ID metadata)
 * 2. Look for field named "id", "key", or ending with "_id"
 * 3. If no stable source key exists, use IdentityStrategy.ROW_HASH.
 * 4. First-field fallback is a last resort for sources that require a selected source key.
 */
private void identifyPrimaryKeys(ObjectMetadata object) {
    List<FieldMetadata> fields = object.getFields();
    boolean hasPk = false;

    for (FieldMetadata field : fields) {
        String name = field.getName().toLowerCase();

        // Common PK patterns
        if (name.equals("id") ||
            name.equals("key") ||
            name.endsWith("_id") && name.length() > 3 ||
            name.equals(object.getName() + "_id")) {

            field.setSourcePrimaryKey(true);
            field.setNillable(false);
            hasPk = true;
            log.debug("Identified primary key: {}", field.getName());
            break;  // Usually only one PK
        }
    }

    // Last-resort fallback: enable only when this source requires a selected source key
    // and the field order is stable/documented enough to trust.
    boolean allowFirstFieldFallback = false;
    if (!hasPk && allowFirstFieldFallback && !fields.isEmpty()) {
        FieldMetadata firstField = fields.get(0);
        firstField.setSourcePrimaryKey(true);
        firstField.setNillable(false);
        hasPk = true;
        log.warn("No declared PK for {}, using first field as last-resort key: {}",
                 object.getName(), firstField.getName());
    }

    object.setIdentityStrategy(hasPk ? IdentityStrategy.SOURCE_KEY : IdentityStrategy.ROW_HASH);
}
```

---

## Step 3: Implement Cursor Field Identification

Cursor fields enable incremental sync. There are THREE valid patterns:

### Pattern 1: identifyCursorFields() Method (Recommended)

```java
/**
 * Identify fields suitable for cursor-based incremental sync.
 *
 * Good cursor fields:
 * - Timestamp fields that update on modification
 * - Auto-incrementing IDs (for append-only data)
 *
 * Bad cursor fields:
 * - Created timestamps (misses updates)
 * - Non-indexed fields (slow queries)
 */
private void identifyCursorFields(ObjectMetadata object) {
    for (FieldMetadata field : object.getFields()) {
        if (isCursorCandidate(field)) {
            field.setSourceCursorField(true);
            field.setCursorCapable(true);
            field.setFilterable(true);
            log.debug("Identified cursor field: {} (type: {})",
                      field.getName(), field.getOriginalDataType());
        }
    }

    // Mark cursor field identification as complete
    object.setCursorFieldLocked(true);
}

private boolean isCursorCandidate(FieldMetadata field) {
    String name = field.getName().toLowerCase();
    CanonicalType type = field.getCanonicalType();

    // Timestamp fields with modification semantics
    if (type == CanonicalType.INSTANT ||
        type == CanonicalType.LOCALDATETIME ||
        type == CanonicalType.LOCALDATE) {
        return name.contains("modified") ||
               name.contains("updated") ||
               name.contains("changed") ||
               name.equals("_dateupdated") ||
               name.equals("systemmodstamp") ||  // Salesforce pattern
               name.equals("lastmodifieddate");
    }

    // Integer fields that might be auto-incrementing
    if (type == CanonicalType.LONG && name.equals("version")) {
        return true;
    }

    return false;
}
```

### Pattern 2: Inline Setting During Schema Building

```java
// Set cursor field directly when creating FieldMetadata
for (SourceField sourceField : sourceSchema) {
    FieldMetadata field = new FieldMetadata();
    field.setName(normalizeFieldName(sourceField.getName()));
    field.setOriginalName(sourceField.getName());
    CanonicalType canonicalType = mapType(sourceField.getType());
    field.setCanonicalType(canonicalType);
    field.setOriginalDataType(sourceField.getType());  // CRITICAL
    field.setPrimaryKeyCapable(FieldCapabilityUtil.isPrimaryKeyCapable(canonicalType));
    field.setCursorCapable(FieldCapabilityUtil.isCursorCapable(canonicalType));

    // Check if this is the cursor field
    if (sourceField.getName().equalsIgnoreCase("ModifiedDate") ||
        sourceField.getName().equalsIgnoreCase("LastModifiedTime")) {
        field.setSourceCursorField(true);
        field.setCursorCapable(true);
        field.setFilterable(true);
    }

    fields.add(field);
}

object.setCursorFieldLocked(true);  // MUST call this
```

### Pattern 3: Utility Class Delegation

```java
// Main connector delegates to utility class
private void identifyCursorFields(ObjectMetadata object) {
    {Name}MetadataUtil.identifyCursorFields(object);
}

// Utility class has the implementation
public class {Name}MetadataUtil {
    public static void identifyCursorFields(ObjectMetadata object) {
        for (FieldMetadata field : object.getFields()) {
            if (isCursorCandidate(field)) {
                field.setSourceCursorField(true);
                field.setCursorCapable(true);
                field.setFilterable(true);
            }
        }
        object.setCursorFieldLocked(true);
    }

    private static boolean isCursorCandidate(FieldMetadata field) {
        // ... logic here
    }
}
```

**CRITICAL**: Whichever pattern you use, you MUST:
1. Call `setCursorFieldLocked(true)` on the ObjectMetadata
2. Set `setSourceCursorField(true)`, `setCursorCapable(true)`, and `setFilterable(true)` on source-discovered cursor fields

Do not set `setPrimaryKey(true)` or `setCursorField(true)` in source schema discovery. Those are effective runtime/user-selection flags populated by the metadata merge layer from `sourcePrimaryKey` and `sourceCursorField` unless the user overrides them.

---

## Step 4: Implement schema(request) Method

### For Static Schema (Known Objects)

```java
@Override
public SchemaResponse schema(SchemaRequest request) throws ConnectorException {
    log.info("Discovering schema for {}", getName());

    try {
        // Ensure we're initialized
        String token = tokenManager.getAccessToken();

        List<ObjectMetadata> objects = new ArrayList<>();

        // Add static objects with known schemas
        objects.add(createJourneySchema());
        objects.add(createEventDefinitionSchema());
        objects.add(createAssetSchema());
        // ... more objects

        log.info("Discovered {} objects", objects.size());
        return SchemaResponse.fromObjects(objects);

    } catch (Exception e) {
        throw new ConnectorException(
            "Schema discovery failed: " + e.getMessage(), e,
            ConnectorException.ErrorType.SYSTEM_ERROR);
    }
}

private ObjectMetadata createJourneySchema() {
    ObjectMetadata object = new ObjectMetadata();
    object.setName("journey");
    object.setFullyQualifiedName("journey");
    object.setType("TABLE");
    object.setObjectType(ObjectType.PRIMARY);
    object.setDescription("Marketing journeys");

    // Store endpoint for read() phase
    object.putCustomAttribute("api_endpoint", "/interaction/v1/interactions");
    object.putCustomAttribute("api_type", "REST");

    List<FieldMetadata> fields = new ArrayList<>();

    // Primary key field
    fields.add(createField("id", "ID", CanonicalType.STRING, "String", true));

    // Regular fields - note originalDataType for each!
    fields.add(createField("key", CanonicalType.STRING, "String"));
    fields.add(createField("name", CanonicalType.STRING, "String"));
    fields.add(createField("version", CanonicalType.LONG, "Integer"));
    fields.add(createField("status", CanonicalType.STRING, "String"));
    fields.add(createField("description", CanonicalType.STRING, "String"));
    fields.add(createField("created_date", CanonicalType.INSTANT, "DateTime"));
    fields.add(createField("modified_date", CanonicalType.INSTANT, "DateTime"));
    fields.add(createField("category_id", CanonicalType.LONG, "Integer"));
    fields.add(createField("entry_mode", CanonicalType.STRING, "String"));
    fields.add(createField("goals", CanonicalType.JSON, "Object"));
    fields.add(createField("activities", CanonicalType.JSON, "Array"));

    object.setFields(fields);

    // Identify keys
    identifyPrimaryKeys(object);    // Sets 'id' as PK
    identifyCursorFields(object);   // Sets 'modified_date' as cursor

    boolean hasCursor = object.getFields().stream()
        .anyMatch(field -> Boolean.TRUE.equals(field.getSourceCursorField()));
    object.setIncrementalStrategy(
        hasCursor ? IncrementalStrategy.COLUMN_CURSOR : IncrementalStrategy.UNSUPPORTED);

    return object;
}
```

### For Dynamic Schema (Discovered Objects)

```java
@Override
public SchemaResponse schema(SchemaRequest request) throws ConnectorException {
    log.info("Discovering schema for {}", getName());

    try {
        String token = tokenManager.getAccessToken();
        List<ObjectMetadata> objects = new ArrayList<>();

        // Add static objects
        objects.add(createJourneySchema());
        // ... other static objects

        // Discover dynamic objects (e.g., Data Extensions)
        List<ObjectMetadata> dynamicObjects = discoverDataExtensions(token);
        objects.addAll(dynamicObjects);

        log.info("Discovered {} total objects ({} static, {} dynamic)",
                 objects.size(),
                 objects.size() - dynamicObjects.size(),
                 dynamicObjects.size());

        return SchemaResponse.fromObjects(objects);

    } catch (Exception e) {
        throw new ConnectorException(
            "Schema discovery failed: " + e.getMessage(), e,
            ConnectorException.ErrorType.SYSTEM_ERROR);
    }
}

private List<ObjectMetadata> discoverDataExtensions(String token) throws IOException {
    List<ObjectMetadata> objects = new ArrayList<>();

    // Fetch Data Extensions via SOAP API
    List<DataExtension> dataExtensions = soapClient.retrieveDataExtensions(token);

    for (DataExtension de : dataExtensions) {
        // Determine object name with prefix
        String prefix = getDataExtensionPrefix(de);
        String objectName = prefix + normalizeFieldName(de.getName());

        ObjectMetadata object = new ObjectMetadata();
        object.setName(objectName);
        object.setFullyQualifiedName(objectName);
        object.setType("TABLE");
        object.setObjectType(ObjectType.PRIMARY);
        object.setDescription(de.getDescription());

        // Store DE key for read() phase
        object.putCustomAttribute("de_customer_key", de.getCustomerKey());
        object.putCustomAttribute("api_type", "DE_REST");

        // Fetch fields for this DE
        List<DataExtensionField> deFields = soapClient.retrieveDataExtensionFields(
            token, de.getCustomerKey());

        List<FieldMetadata> fields = new ArrayList<>();
        for (DataExtensionField deField : deFields) {
            FieldMetadata field = new FieldMetadata();
            field.setName(normalizeFieldName(deField.getName()));
            field.setOriginalName(deField.getName());
            field.setLabel(deField.getName());
            CanonicalType canonicalType = mapSfmcType(deField.getFieldType());
            field.setCanonicalType(canonicalType);
            field.setOriginalDataType(deField.getFieldType());  // CRITICAL
            field.setPrimaryKeyCapable(FieldCapabilityUtil.isPrimaryKeyCapable(canonicalType));
            field.setCursorCapable(FieldCapabilityUtil.isCursorCapable(canonicalType));
            if (Boolean.TRUE.equals(deField.getIsPrimaryKey())) {
                field.setSourcePrimaryKey(true);
            }
            field.setNillable(!deField.getIsRequired());

            fields.add(field);
        }

        object.setFields(fields);

        // Identify cursor fields for this DE
        identifyCursorFields(object);
        boolean hasPrimaryKey = object.getFields().stream()
            .anyMatch(field -> Boolean.TRUE.equals(field.getSourcePrimaryKey()));
        object.setIdentityStrategy(
            hasPrimaryKey ? IdentityStrategy.SOURCE_KEY : IdentityStrategy.ROW_HASH);

        // Check if incremental sync is possible
        boolean hasCursor = object.getFields().stream()
            .anyMatch(field -> Boolean.TRUE.equals(field.getSourceCursorField()));
        object.setIncrementalStrategy(
            hasCursor ? IncrementalStrategy.COLUMN_CURSOR : IncrementalStrategy.UNSUPPORTED);

        objects.add(object);
    }

    return objects;
}
```

---

## Step 5: Store Context for Read Phase

During schema discovery, store information needed during read():

```java
// Store API-specific metadata in customAttributes
object.putCustomAttribute("api_type", "REST");           // REST, SOAP, DE_REST
object.putCustomAttribute("api_endpoint", "/v1/interactions");
object.putCustomAttribute("de_customer_key", "abc123");  // For Data Extensions
object.putCustomAttribute("page_size", "50");            // API-specific page size

// IMPORTANT: Document API timezone behavior for read() phase
// Many APIs return timestamps in non-UTC timezones without indicator!
object.putCustomAttribute("api_timezone", "UTC");        // or "America/Chicago" for SFMC
object.putCustomAttribute("timestamp_format", "ISO8601"); // or "EPOCH_MILLIS"

// During read(), retrieve this metadata:
String apiType = object.getCustomAttributes().get("api_type");
String endpoint = object.getCustomAttributes().get("api_endpoint");
String timezone = object.getCustomAttributes().get("api_timezone");
```

### API Timezone Patterns

| API | Timezone | Notes |
|-----|----------|-------|
| Salesforce | UTC | Standard |
| HubSpot | UTC | But milliseconds, not ISO |
| SFMC | America/Chicago (CST) | No timezone indicator! |
| Airtable | UTC | Standard |
| Legacy systems | Varies | Often server local time |

**Why this matters**: If API returns timestamps in non-UTC without indicator, your read() phase must convert to UTC for storage. Store this info during schema(request) so read() knows how to handle timestamps.

---

## Step 6: Implement Type Mapping

```java
/**
 * Map source system types to CanonicalType.
 * ALWAYS preserve the original type name for originalDataType.
 */
private CanonicalType mapSfmcType(String sfmcType) {
    if (sfmcType == null) {
        return CanonicalType.STRING;  // Safe default
    }

    switch (sfmcType.toLowerCase()) {
        case "text":
        case "emailaddress":
        case "phone":
        case "locale":
            return CanonicalType.STRING;

        case "number":
            return CanonicalType.LONG;

        case "decimal":
            return CanonicalType.DOUBLE;

        case "boolean":
            return CanonicalType.BOOLEAN;

        case "date":
            return CanonicalType.INSTANT;  // SFMC dates include time

        default:
            log.warn("Unknown SFMC type '{}', defaulting to STRING", sfmcType);
            return CanonicalType.STRING;
    }
}
```

---

## Gate Verification

### Automated Checks

```bash
# 1. Compile from the platform root with reactor dependencies
cd <platform-root>
mvn -pl connectors/supaflow-connector-{name} -am compile

# 2. Run verification script
bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>
```

### Expected Verification Results

| Check | Expected Result |
|-------|-----------------|
| CHECK 3.5 | ✓ ObjectMetadata + FieldMetadata requirements |
| CHECK 12 | ✓ Primary key and cursor field identification |
| CHECK 13 | ✓ Cursor field setting invoked in schema() |
| Previous checks | Still passing |

### Manual Checklist

Before proceeding to Phase 5, confirm ALL of the following:

| Check | Verification |
|-------|--------------|
| ☐ schema(request) returns at least one ObjectMetadata | Run schema(request) |
| ☐ Every ObjectMetadata has a name | Code review |
| ☐ Every ObjectMetadata has `fullyQualifiedName` set | Code review |
| ☐ Every ObjectMetadata has `type` set, usually `"TABLE"` | Code review |
| ☐ Every ObjectMetadata has `incrementalStrategy` set to `COLUMN_CURSOR`, `CONNECTOR_MANAGED`, or `UNSUPPORTED` | Code review |
| ☐ No ObjectMetadata uses legacy `IncrementalStrategy.NONE` | Code review |
| ☐ Every ObjectMetadata has `identityStrategy` set to `SOURCE_KEY` or `ROW_HASH` | Code review |
| ☐ Normal source objects set `objectType` to `ObjectType.PRIMARY` unless they are association/history/metadata objects | Code review |
| ☐ Every ObjectMetadata has at least one field | Code review |
| ☐ Every FieldMetadata has `name` set | Code review |
| ☐ **CRITICAL**: Every FieldMetadata has `originalDataType` set | `grep -c "setOriginalDataType"` |
| ☐ Every FieldMetadata has `canonicalType` set | Code review |
| ☐ Every FieldMetadata has `primaryKeyCapable` and `cursorCapable` set | Code review |
| ☐ Every BIGDECIMAL field has precision `1..38` and scale `0..min(37, precision)` | Code review |
| ☐ Fields set `sourcePrimaryKey` / `sourceCursorField` only for true defaults, never `false` | Code review |
| ☐ identifyCursorFields() or equivalent is called | Code review |
| ☐ setCursorFieldLocked(true) is called on each object | Code review |
| ☐ customAttributes store info needed for read() | Code review |
| ☐ Sample-based connectors use `SchemaGenerator` + `RecordSupplier` (not ad-hoc guessing in multiple places) | Code review |
| ☐ CHECK 3.5, 12, 13 pass | Verification script |

### Verification Commands

```bash
# Count setOriginalDataType calls (should be > 0 for each object)
grep -c "setOriginalDataType" src/main/java/**/*.java

# Check required object metadata strategies
grep -n "setType\|setIncrementalStrategy\|setIdentityStrategy" src/main/java/**/*.java

# Check for cursor field handling
grep -n "setSourceCursorField\|identifyCursorFields\|setCursorFieldLocked" src/main/java/**/*.java

# Check for primary key handling
grep -n "setSourcePrimaryKey" src/main/java/**/*.java
```

### Show Your Work

Before proceeding to Phase 5, show:

1. Output of `mvn -pl connectors/supaflow-connector-{name} -am compile`
2. Output of `bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>` (CHECKs 3.5, 12, 13)
3. Sample ObjectMetadata output (object name, field count, PK field, cursor field)
4. Confirmation that originalDataType is set on every field

---

## Common Mistakes to Avoid

| Mistake | Why It's Wrong | Correct Approach |
|---------|----------------|------------------|
| **Not setting originalDataType** | Schema incomplete, breaks tracking | ALWAYS set for every field |
| Setting `sourcePrimaryKey(false)` or `sourceCursorField(false)` | Sparse source flags must be true or unset | Only call source flag setters when the value is true |
| Missing `primaryKeyCapable` or `cursorCapable` | Metadata compliance fails | Set capability booleans for every field |
| Missing `type`, `incrementalStrategy`, or `identityStrategy` on ObjectMetadata | Metadata compliance fails | Set all required object metadata fields |
| Using `IncrementalStrategy.NONE` | Legacy value rejected by compliance checks | Use `UNSUPPORTED` when incremental sync is unavailable |
| Inventing a PK when the source has none | Deduplication can become unstable | Prefer source-declared keys; otherwise use `IdentityStrategy.ROW_HASH` |
| identifyCursorFields() defined but not called | Incremental sync won't work | Must call in schema(request) for each object |
| Not calling setCursorFieldLocked(true) | System doesn't know cursor is set | Always call after identifying cursors |
| Using wrong CanonicalType | Type conversion errors | Match source type semantics |
| Not storing context for read() | Can't read data properly | Use customAttributes |
| Hardcoding field lists | Misses new fields | Discover from API when possible |
| Setting createdDate as cursor | Misses updates | Use modifiedDate or equivalent |

---

## Next Phase

Once all gate checks pass, proceed to:
→ **PHASE_5_READ_OPERATIONS.md**
