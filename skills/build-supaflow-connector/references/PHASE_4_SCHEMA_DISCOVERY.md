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

1. What fields does ObjectMetadata have? (name, displayName, fields, category, customAttributes, etc.)
2. What fields does FieldMetadata have? (name, canonicalType, originalDataType, isPrimaryKey, isCursorField, etc.)
3. **CRITICAL**: What is `originalDataType` and why must it ALWAYS be set?
4. What CanonicalTypes are available? (STRING, LONG, DOUBLE, BOOLEAN, INSTANT, LOCALDATE, JSON, etc.)
5. How do you mark a field as primary key?
6. How do you mark a field as cursor field?
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
object.setDisplayName("Journey");             // Human-readable name
object.setFields(fieldList);                  // List<FieldMetadata>

// Optional but recommended
object.setCategory("Interactions");           // Grouping in UI
object.setDescription("Marketing journeys");  // Help text

// Sync capabilities
object.setIncrementalSyncSupported(true);     // Can this object sync incrementally?
object.setCursorFieldLocked(true);            // Cursor field has been identified

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
// PRIMARY KEY - Set for at least one field per object
// ================================================================

field.setPrimaryKey(true);                     // Is this the primary key?

// ================================================================
// CURSOR FIELD - For incremental sync
// ================================================================

field.setCursorField(true);                    // Can this field be used as cursor?
field.setSourceCursorField(true);              // Source supports filtering on this
field.setFilterable(true);                     // Can filter API by this field

// ================================================================
// OPTIONAL FIELDS
// ================================================================

field.setDisplayName("Modified Date");         // Human-readable name
field.setDescription("Last modification time"); // Help text
field.setNullable(true);                       // Can be null?
field.setSourcePath("modifiedDate");           // JSON path in API response
```

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
    STRING,      // Text data
    LONG,        // Integer numbers (64-bit)
    DOUBLE,      // Floating point numbers
    BOOLEAN,     // True/false
    INSTANT,     // Timestamp with timezone (ISO 8601)
    LOCALDATE,   // Date without time (YYYY-MM-DD)
    LOCALTIME,   // Time without date (HH:MM:SS)
    JSON,        // Complex/nested structures
    BYTES        // Binary data
}
```

### Type Mapping Guidelines

| Source Type Pattern | CanonicalType | Notes |
|--------------------|---------------|-------|
| string, text, varchar, char | STRING | |
| int, integer, number, bigint | LONG | Use for whole numbers |
| float, double, decimal, numeric | DOUBLE | Use for decimals |
| boolean, bool, bit | BOOLEAN | |
| datetime, timestamp, instant | INSTANT | With timezone |
| date | LOCALDATE | Date only |
| time | LOCALTIME | Time only |
| json, object, array, map | JSON | Complex structures |
| binary, blob, bytes | BYTES | |

---

## Step 1: Create FieldMetadata Builder Helper

Create a helper to ensure all required fields are set:

```java
/**
 * Helper to create FieldMetadata with all required fields.
 * Ensures originalDataType is ALWAYS set.
 */
private FieldMetadata createField(
        String name,
        String displayName,
        CanonicalType canonicalType,
        String originalDataType,  // REQUIRED - source system type
        boolean isPrimaryKey,
        String sourcePath) {

    FieldMetadata field = new FieldMetadata();

    // Required
    field.setName(name);
    field.setCanonicalType(canonicalType);
    field.setOriginalDataType(originalDataType);  // CRITICAL - MUST set

    // Optional but recommended
    field.setDisplayName(displayName != null ? displayName : name);
    field.setSourcePath(sourcePath != null ? sourcePath : name);
    field.setPrimaryKey(isPrimaryKey);
    field.setNullable(!isPrimaryKey);  // PKs are not nullable

    return field;
}

// Convenience overload for non-PK fields
private FieldMetadata createField(
        String name,
        CanonicalType canonicalType,
        String originalDataType,
        String sourcePath) {
    return createField(name, null, canonicalType, originalDataType, false, sourcePath);
}
```

---

## Step 2: Implement Primary Key Identification

Every object MUST have at least one primary key field:

```java
/**
 * Identify and mark primary key fields.
 *
 * Strategy:
 * 1. Look for field named "id", "key", or ending with "_id"
 * 2. Look for field marked as PK in source schema
 * 3. If no obvious PK, use first field as PK
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

            field.setPrimaryKey(true);
            field.setNullable(false);
            hasPk = true;
            log.debug("Identified primary key: {}", field.getName());
            break;  // Usually only one PK
        }
    }

    // Fallback: use first field if no PK found
    if (!hasPk && !fields.isEmpty()) {
        FieldMetadata firstField = fields.get(0);
        firstField.setPrimaryKey(true);
        firstField.setNullable(false);
        log.warn("No obvious PK for {}, using first field: {}",
                 object.getName(), firstField.getName());
    }
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
            field.setCursorField(true);
            field.setSourceCursorField(true);
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
    if (type == CanonicalType.INSTANT || type == CanonicalType.LOCALDATE) {
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
    field.setCanonicalType(mapType(sourceField.getType()));
    field.setOriginalDataType(sourceField.getType());  // CRITICAL

    // Check if this is the cursor field
    if (sourceField.getName().equalsIgnoreCase("ModifiedDate") ||
        sourceField.getName().equalsIgnoreCase("LastModifiedTime")) {
        field.setCursorField(true);
        field.setSourceCursorField(true);
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
                field.setCursorField(true);
                field.setSourceCursorField(true);
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
2. Set `setCursorField(true)`, `setSourceCursorField(true)`, and `setFilterable(true)` on cursor fields

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
    object.setDisplayName("Journey");
    object.setCategory("Interactions");
    object.setDescription("Marketing journeys");

    // Store endpoint for read() phase
    object.putCustomAttribute("api_endpoint", "/interaction/v1/interactions");
    object.putCustomAttribute("api_type", "REST");

    List<FieldMetadata> fields = new ArrayList<>();

    // Primary key field
    fields.add(createField("id", "ID", CanonicalType.STRING, "String", true, "id"));

    // Regular fields - note originalDataType for each!
    fields.add(createField("key", CanonicalType.STRING, "String", "key"));
    fields.add(createField("name", CanonicalType.STRING, "String", "name"));
    fields.add(createField("version", CanonicalType.LONG, "Integer", "version"));
    fields.add(createField("status", CanonicalType.STRING, "String", "status"));
    fields.add(createField("description", CanonicalType.STRING, "String", "description"));
    fields.add(createField("created_date", CanonicalType.INSTANT, "DateTime", "createdDate"));
    fields.add(createField("modified_date", CanonicalType.INSTANT, "DateTime", "modifiedDate"));
    fields.add(createField("category_id", CanonicalType.LONG, "Integer", "categoryId"));
    fields.add(createField("entry_mode", CanonicalType.STRING, "String", "entryMode"));
    fields.add(createField("goals", CanonicalType.JSON, "Object", "goals"));
    fields.add(createField("activities", CanonicalType.JSON, "Array", "activities"));

    object.setFields(fields);

    // Identify keys
    identifyPrimaryKeys(object);    // Sets 'id' as PK
    identifyCursorFields(object);   // Sets 'modified_date' as cursor

    object.setIncrementalSyncSupported(true);

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
        object.setDisplayName(de.getName());
        object.setCategory("Data Extensions");
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
            field.setDisplayName(deField.getName());
            field.setCanonicalType(mapSfmcType(deField.getFieldType()));
            field.setOriginalDataType(deField.getFieldType());  // CRITICAL
            field.setSourcePath(deField.getName());
            field.setPrimaryKey(deField.getIsPrimaryKey());
            field.setNullable(!deField.getIsRequired());

            fields.add(field);
        }

        object.setFields(fields);

        // Identify cursor fields for this DE
        identifyCursorFields(object);

        // Check if incremental sync is possible
        boolean hasCursor = object.getFields().stream()
            .anyMatch(FieldMetadata::isCursorField);
        object.setIncrementalSyncSupported(hasCursor);

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
| CHECK 4 | ✓ FieldMetadata requirements (originalDataType, canonicalType) |
| CHECK 12 | ✓ Primary key and cursor field identification |
| CHECK 13 | ✓ Cursor field setting invoked in schema() |
| Previous checks | Still passing |

### Manual Checklist

Before proceeding to Phase 5, confirm ALL of the following:

| Check | Verification |
|-------|--------------|
| ☐ schema(request) returns at least one ObjectMetadata | Run schema(request) |
| ☐ Every ObjectMetadata has a name | Code review |
| ☐ Every ObjectMetadata has at least one field | Code review |
| ☐ Every FieldMetadata has `name` set | Code review |
| ☐ **CRITICAL**: Every FieldMetadata has `originalDataType` set | `grep -c "setOriginalDataType"` |
| ☐ Every FieldMetadata has `canonicalType` set | Code review |
| ☐ At least one field per object is marked as primaryKey | Code review |
| ☐ identifyCursorFields() or equivalent is called | Code review |
| ☐ setCursorFieldLocked(true) is called on each object | Code review |
| ☐ customAttributes store info needed for read() | Code review |
| ☐ Sample-based connectors use `SchemaGenerator` + `RecordSupplier` (not ad-hoc guessing in multiple places) | Code review |
| ☐ CHECK 4, 12, 13 pass | Verification script |

### Verification Commands

```bash
# Count setOriginalDataType calls (should be > 0 for each object)
grep -c "setOriginalDataType" src/main/java/**/*.java

# Check for cursor field handling
grep -n "setCursorField\|identifyCursorFields\|setCursorFieldLocked" src/main/java/**/*.java

# Check for primary key handling
grep -n "setPrimaryKey" src/main/java/**/*.java
```

### Show Your Work

Before proceeding to Phase 5, show:

1. Output of `mvn compile`
2. Output of `bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>` (CHECKs 4, 12, 13)
3. Sample ObjectMetadata output (object name, field count, PK field, cursor field)
4. Confirmation that originalDataType is set on every field

---

## Common Mistakes to Avoid

| Mistake | Why It's Wrong | Correct Approach |
|---------|----------------|------------------|
| **Not setting originalDataType** | Schema incomplete, breaks tracking | ALWAYS set for every field |
| Not marking any field as PK | Deduplication fails | Every object needs at least one PK |
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
