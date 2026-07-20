# Connector Anti-Patterns: What NOT To Do

**Purpose**: This document lists common mistakes that cause connector failures. Read this BEFORE implementing and CHECK your code against it AFTER implementing.

---

## Table of Contents

- [Critical Anti-Patterns (Will Break Connector)](#critical-anti-patterns-will-break-connector)
  - [8b. Missing convertToCanonicalValue Override (JDBC Connectors)](#8b-missing-converttocanonicalvalue-override-jdbc-connectors)
  - [8d. Treating Native JSON Text as a Plain String](#8d-treating-native-json-text-as-a-plain-string)
  - [8e. Serializing Positional JDBC Struct Attributes](#8e-serializing-positional-jdbc-struct-attributes)
- [Moderate Anti-Patterns (May Cause Issues)](#moderate-anti-patterns-may-cause-issues)
  - [8c. Insecure TLS Default (`trustServerCertificate=true`)](#8c-insecure-tls-default-trustservercertificatetrue)
  - [8f. Treating `setFetchSize` as Proven Pagination](#8f-treating-setfetchsize-as-proven-pagination)
  - [8g. Letting Metadata Performance Tests Fall Back](#8g-letting-metadata-performance-tests-fall-back)
- [Minor Anti-Patterns (Code Quality)](#minor-anti-patterns-code-quality)
- [Quick Verification Checklist](#quick-verification-checklist)

---

## Critical Anti-Patterns (Will Break Connector)

### 1. Calling processor.close()

**DO NOT:**
```java
public ReadResponse read(ReadRequest request) throws ConnectorException {
    RecordProcessor processor = request.getRecordProcessor();
    // ... process records ...
    processor.close();  // WRONG! Never call this!
    return response;
}
```

**DO:**
```java
public ReadResponse read(ReadRequest request) throws ConnectorException {
    RecordProcessor processor = request.getRecordProcessor();
    // ... process records with processor.processRecord(record) ...
    // Let executor handle processor lifecycle
    return response;
}
```

**Why**: The executor manages the RecordProcessor lifecycle. Calling close() causes resource conflicts and data loss.

---

### 2. Missing originalDataType on FieldMetadata

**DO NOT:**
```java
FieldMetadata field = new FieldMetadata();
field.setName("created_date");
field.setCanonicalType(CanonicalType.INSTANT);
// Missing setOriginalDataType!
```

**DO:**
```java
FieldMetadata field = new FieldMetadata();
field.setName("created_date");
field.setCanonicalType(CanonicalType.INSTANT);
field.setOriginalDataType("DateTime");  // ALWAYS set this!
```

**Why**: `originalDataType` is required for schema tracking, type conversion logging, and destination DDL generation.

---

### 3. Ignoring SyncState in read()

**DO NOT:**
```java
public ReadResponse read(ReadRequest request) throws ConnectorException {
    // Just fetch all data every time
    String url = baseUrl + "/objects";
    // ... fetch all records ...
}
```

**DO:**
```java
public ReadResponse read(ReadRequest request) throws ConnectorException {
    SyncStateRequest syncState = request.getSyncState();

    boolean isInitialSync = syncState == null || syncState.isInitialSync();
    List<IncrementalField> cursorPosition =
        syncState != null ? syncState.getCursorPosition() : null;
    String lowerBound = cursorPosition == null ? null : cursorPosition.stream()
        .filter(f -> "modified_time".equals(f.getFieldName()))
        .map(IncrementalField::getValue)
        .findFirst()
        .orElse(null);

    String url = baseUrl + "/objects";
    if (!isInitialSync && lowerBound != null) {
        url += "?modifiedAfter=" + lowerBound;  // Filter for incremental
    }
    // ... fetch filtered records ...
}
```

**Why**: Ignoring SyncState means every sync is a full sync, wasting time and resources.

**Current API Note**: Use `request.getSyncState()` which directly returns `SyncStateRequest` (not the old nested `getSyncStateRequest().getSyncState()` pattern).

---

### 3b. Ignoring Cancellation Signals

**DO NOT:**
```java
while (hasMore) {
    response = client.getNextPage();
    // No cancellation checks
}

// Swallow cancellation and keep retrying
} catch (ConnectorException e) {
    retry();
}
```

**DO:**
```java
private void checkCancellation(String phase) throws ConnectorException {
    if (cancellationSupplier != null && cancellationSupplier.getAsBoolean()) {
        throw new ConnectorException("Cancelled during " + phase,
            ConnectorException.ErrorType.CANCELLED);
    }
}

while (hasMore) {
    checkCancellation("pagination");
    response = client.getNextPage();
}

} catch (ConnectorException e) {
    if (e.getErrorType() == ConnectorException.ErrorType.CANCELLED) {
        throw e; // never retry cancellation
    }
    retry();
}
```

**Why**: Cancellation is a control signal, not an error to retry. Missing checks makes jobs unkillable.

---

### 4. Not Calling identifyCursorFields() or Equivalent

**DO NOT:**
```java
private void identifyCursorFields(ObjectMetadata object) {
    // Method exists but never called!
    for (FieldMetadata field : object.getFields()) {
        if (field.getName().contains("modified")) {
            field.setSourceCursorField(true);
        }
    }
}

public SchemaResponse schema(SchemaRequest request) {
    ObjectMetadata obj = createSchema();
    // identifyCursorFields(obj) never called!
    return SchemaResponse.fromObjects(List.of(obj));
}
```

**DO:**
```java
public SchemaResponse schema(SchemaRequest request) {
    ObjectMetadata obj = createSchema();
    identifyCursorFields(obj);  // MUST call this!
    return SchemaResponse.fromObjects(List.of(obj));
}
```

**Why**: Cursor fields must be identified for incremental sync to work.

---

### 5. Missing setCursorFieldLocked(true)

**DO NOT:**
```java
private void identifyCursorFields(ObjectMetadata object) {
    for (FieldMetadata field : object.getFields()) {
        if (isCursorCandidate(field)) {
            field.setSourceCursorField(true);
        }
    }
    // Missing setCursorFieldLocked!
}
```

**DO:**
```java
private void identifyCursorFields(ObjectMetadata object) {
    for (FieldMetadata field : object.getFields()) {
        if (isCursorCandidate(field)) {
            field.setSourceCursorField(true);
            field.setCursorCapable(true);
            field.setFilterable(true);
        }
    }
    object.setCursorFieldLocked(true);  // MUST call this!
}
```

**Why**: The system needs to know cursor identification is complete.

---

### 6. Declaring Capabilities You Don't Implement

**DO NOT:**
```java
public Set<ConnectorCapabilities> getConnectorCapabilities() {
    return EnumSet.of(
        ConnectorCapabilities.REPLICATION_SOURCE,
        ConnectorCapabilities.REPLICATION_DESTINATION
    ); // But write()/load() aren't implemented
}
```

**DO:**
```java
public Set<ConnectorCapabilities> getConnectorCapabilities() {
    return EnumSet.of(ConnectorCapabilities.REPLICATION_SOURCE);
}

public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
    return ConnectorCapabilitiesConfigBuilder.builder()
        .asAPIConnector()  // Always start with the right preset
        .build();
}
```

**Why**: The executor relies on capabilities to determine what operations are available.

---

### 6b. Missing Connector Type Preset in getCapabilitiesConfig()

**DO NOT:**
```java
public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
    return ConnectorCapabilitiesConfigBuilder.builder()
        .requiresStaging(false)
        .requiresExplicitLoadStep(false)
        .build();  // Missing preset! Defaults are wrong for a database connector.
}
```

**DO:**
```java
public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
    return ConnectorCapabilitiesConfigBuilder.builder()
        .asTraditionalDatabase()  // Sets canAutoCreateSchema, supportsHardDeletes, optimization
        .requiresStaging(false)
        .requiresExplicitLoadStep(false)
        .build();
}
```

**Why**: Without a preset, `canAutoCreateSchema` defaults to `false`, which disables schema
evolution mode, auto-resync capabilities, and hard deletes in the UI. This was a real bug in
the SQL Server connector -- it was missing `.asTraditionalDatabase()` and shipped with broken
capabilities for months. Always start with one of: `.asTraditionalDatabase()`,
`.asAPIConnector()`, or `.asCloudWarehouse()`.

For direct database destinations, keep `.asTraditionalDatabase()` but use
`.requiresExplicitLoadStep(true)` because `stage()` is a no-op and `load()` still performs the
database write.

---

### 7. No Source Primary Key on Objects

**DO NOT:**
```java
List<FieldMetadata> fields = new ArrayList<>();
fields.add(createField("name", STRING, "String"));
fields.add(createField("email", STRING, "String"));
// No field marked as primary key!
object.setFields(fields);
```

**DO:**
```java
List<FieldMetadata> fields = new ArrayList<>();
FieldMetadata idField = createField("id", STRING, "String");
idField.setSourcePrimaryKey(true);  // Connector-discovered default business key
idField.setPrimaryKeyCapable(true);
fields.add(idField);
fields.add(createField("name", STRING, "String"));
object.setFields(fields);
```

**Why**: Source primary keys give the metadata merge layer a stable default for deduplication and upsert logic. Source discovery should not set `primaryKey` directly.

---

### 8. Hardcoded Field Parsing (Schema/Parse Mismatch)

**DO NOT:**
```java
// Hardcoded parsing that doesn't match schema - causes null columns
private Map<String, String> parseResult(String resultXml, String objectType) {
    switch (objectType) {
        case "Subscriber":
            // Only extracts 7 fields, but schema declares 18!
            record.put("ID", extractXml(resultXml, "ID"));
            record.put("SubscriberKey", extractXml(resultXml, "SubscriberKey"));
            // ... missing 11 other fields declared in schema
            break;
    }
}
```

**DO:**
```java
// Metadata-driven parsing - extracts whatever fields are in the schema
private Map<String, String> parseResultDynamic(String resultXml, List<String> requestedProperties) {
    Map<String, String> record = new HashMap<>();
    for (String property : requestedProperties) {
        if (property.contains(".")) {
            // Nested property like "ParentFolder.ID"
            String[] parts = property.split("\\.", 2);
            record.put(property, extractNestedXml(resultXml, parts[0], parts[1]));
        } else {
            record.put(property, extractXml(resultXml, property));
        }
    }
    return record;
}

// Get properties from ObjectMetadata - single source of truth
List<String> properties = objectMetadata.getFields().stream()
    .map(FieldMetadata::getName)
    .collect(Collectors.toList());
```

**Why**: Hardcoded parsing creates a mismatch between schema and actual data:
- Schema declares fields that parsing never extracts → always null columns
- Requires manual maintenance when fields change
- Three sources of truth (schema, request properties, parse logic) can drift

---

### 8b. Missing convertToCanonicalValue Override (JDBC Connectors)

**DO NOT:**
```java
// Rely on the base class to handle all JDBC driver types
// Base class calls CanonicalTypeUtil.convertToCanonicalValue() which
// only knows about standard Java types (String, BigDecimal, Timestamp, etc.)
```

**DO:**
```java
@Override
public String convertToCanonicalValue(Object value, CanonicalType canonicalType) {
    if (value == null) {
        return CanonicalTypeUtil.NULL_PLACEHOLDER;
    }
    try {
        // Intercept proprietary driver types BEFORE they reach the base class
        if (value.getClass().getName().startsWith("com.microsoft.sqlserver.")) {
            return value.toString();
        }
        if (value.getClass().getName().startsWith("org.postgresql.")) {
            if (value instanceof java.sql.SQLXML) {
                return ((java.sql.SQLXML) value).getString();
            }
            return value.toString();
        }
        return super.convertToCanonicalValue(value, canonicalType);
    } catch (Exception e) {
        log.warn("Conversion failed for {} of type {}: {}", value, canonicalType, e.getMessage());
        return value.toString();
    }
}
```

**Why**: Every JDBC driver returns proprietary Java objects for database-specific types:
- SQL Server: `microsoft.sql.DateTimeOffset`, `Geometry`, `Geography`
- PostgreSQL: `PGobject`, `PGInterval`, `PgArray`
- Oracle: `oracle.sql.TIMESTAMP`, `STRUCT`

The base class utility method does not know these types and throws `ClassCastException` at runtime. This is silent during schema discovery (which only reads metadata, not values) and only surfaces when actual data is read -- making it easy to miss during development if integration tests only check schema discovery.

---

### 8d. Treating Native JSON Text as a Plain String

**DO NOT:**
```java
if (value instanceof String) {
    return JSON.writeValueAsString(value);
}
```

This turns a JSON object payload into a quoted JSON string.

**DO:**
```java
if (canonicalType == CanonicalType.JSON && value instanceof CharSequence text) {
    return JSON.writeValueAsString(JSON.readTree(text.toString()));
}
```

Branch on both canonical type and runtime value shape. Add driver-facing tests for JSON objects,
arrays, and scalars; comparing only the textual wrapper is insufficient.

---

### 8e. Serializing Positional JDBC Struct Attributes

**DO NOT:**
```java
if (value instanceof Struct struct) {
    return JSON.writeValueAsString(struct.getAttributes());
}
```

`Struct.getAttributes()` preserves positions but not nested field names. The resulting JSON array
can look valid while changing the source value's meaning. The same class of silent loss occurs
when a driver materializes a high-precision source temporal value in a narrower JDBC class.

**DO:**
```java
@Override
protected String renderSelectItem(FieldMetadata field) {
    if (isStructuredSourceType(field.getOriginalDataType())) {
        return sourceJsonProjection(field) + " AS " + field.getFormattedName();
    }
    if (driverTruncatesTime(field.getOriginalDataType())) {
        return sourceStringProjection(field) + " AS " + field.getFormattedName();
    }
    return super.renderSelectItem(field);
}
```

Project to a lossless source-native representation before ResultSet extraction and keep the
original alias. Apply the hook to every read strategy. Reject any raw lossy `Struct` fallback, then
prove named nested fields and exact fractional temporal precision in a live source IT.

---

## Moderate Anti-Patterns (May Cause Issues)

### 8c. Insecure TLS Default (`trustServerCertificate=true`)

**DO NOT:**
```java
@Property(
    label = "Trust Server Certificate",
    defaultValue = "true"  // insecure by default
)
public String trustServerCertificate;
```

**DO:**
```java
@Property(
    label = "Trust Server Certificate",
    defaultValue = "false"  // secure default
)
public String trustServerCertificate;
```

**Why**: Defaulting certificate trust to `true` disables server certificate validation and can hide man-in-the-middle risks. Keep secure defaults for production and let users explicitly opt in for local/dev/self-signed setups.

---

### 8f. Treating `setFetchSize` as Proven Pagination

**DO NOT:**
```java
statement.setFetchSize(recommendedPageSize);
log.info("Reading in {}-row pages", recommendedPageSize);
```

The JDBC call is a hint. A driver may only store it while using a separate REST `MaxResults`
setting, fixed Arrow batch, or native transport buffer. It also does not add SQL keyset/range
chunking.

**DO:** Audit the pinned driver and distinguish:

1. connector SQL chunk/range size;
2. JDBC fetch hint;
3. driver protocol page size; and
4. native API batch, buffer, and stream count.

Use live telemetry to record the actual transport and peak memory. Do not infer unload behavior
from a "high throughput" flag; unload creates external artifacts, while native APIs may still
stream directly through the agent.

---

### 8g. Letting Metadata Performance Tests Fall Back

**DO NOT:**
```java
long start = System.nanoTime();
List<ObjectMetadata> metadata = connector.schema(); // may fall back per table
assertThat(elapsed(start)).isLessThan(MAX_MS);
```

If the bulk path fails because of permissions or provider quota, the timed call can silently enter
the table-count-dependent JDBC baseline. The test then burns time and quota without isolating the
bulk implementation.

**DO:** Expose a test-only bulk-only/fail-fast entry point, assert the selected fetch path, and
bound metadata query count as well as elapsed time. Keep exact bulk-to-legacy field parity behind
an explicit environment flag. After parity is established, run the bulk path alone for routine
catalog-scale validation.

---

### 9. Wrong Pagination Pattern

**DO NOT:**
```java
// Assuming page-based when API uses cursor
int page = 1;
while (true) {
    response = api.get("?page=" + page);  // API doesn't support this!
    page++;
}
```

**DO:**
```java
// Check API documentation for correct pattern
String cursor = null;
while (true) {
    String url = cursor != null ? "?cursor=" + cursor : "";
    response = api.get(url);
    cursor = response.get("next_cursor");
    if (cursor == null) break;
}
```

**Why**: Wrong pagination causes missing data or infinite loops.

---

### 9. Ignoring lookbackTimeSeconds

**DO NOT:**
```java
if (!isInitialSync && cursorPosition != null) {
    url += "?modifiedAfter=" + cursorPosition;  // Ignoring lookback
}
```

**DO:**
```java
if (!isInitialSync && cursorPosition != null) {
    Long lookback = request.getLookbackTimeSeconds();
    String effectiveCursor = applyLookback(cursorPosition, lookback);
    url += "?modifiedAfter=" + effectiveCursor;
}

private String applyLookback(String cursor, Long lookbackSeconds) {
    if (lookbackSeconds == null || lookbackSeconds <= 0) return cursor;
    Instant c = Instant.parse(cursor);
    return c.minusSeconds(lookbackSeconds).toString();
}
```

**Why**: Lookback handles late-arriving or out-of-order data.

---

### 9b. Using Raw maxCursorSeen as the Only Boundary State (CRITICAL)

**DO NOT:**
```java
// WRONG: Track maximum cursor value seen in records
Instant maxCursorSeen = Instant.EPOCH;
for (JsonNode item : items) {
    processor.processRecord(record);

    Object cursorValue = record.get(cursorFieldName);
    if (cursorValue != null) {
        Instant recordCursor = parseTimestamp(cursorValue);
        if (recordCursor.isAfter(maxCursorSeen)) {
            maxCursorSeen = recordCursor;  // WRONG!
        }
    }
}
result.newCursorPosition = maxCursorSeen.toString();  // WRONG!
```

**DO:**
```java
// CORRECT for bounded-window APIs: use CutoffTimeSyncUtils
import io.supaflow.connector.sdk.util.CutoffTimeSyncUtils;

// At START of read():
String cutoffTimeStr = CutoffTimeSyncUtils.formatCutoffTimeIso(request.getSyncState());

// Fetch and process records normally...
fetchAndProcessRecords(request);

// At END of read() - just call applyCutoffTimeToResult():
RecordProcessingResult result = request.getRecordProcessor().completeProcessing();
result = CutoffTimeSyncUtils.applyCutoffTimeToResult(result, request, cutoffTimeStr);

// The shared SDK policy handles:
// - Initial baseline with records -> persists cutoffTime
// - Empty initial baseline -> suppresses end cursor and remains initial
// - Subsequent incremental window -> persists cutoffTime, including zero rows
// - Cutoff state never carries recordCount
```

For other source shapes:

```java
// CORRECT for countable lower-bound sources:
// keep the cursor in IncrementalField.value and the boundary count in
// IncrementalField.recordCount so the next run can choose > vs >=.

// CORRECT for non-countable lower-bound sources:
// keep the cursor in IncrementalField.value and carry boundary dedup
// state in SyncState.customState["incremental_boundary"].
```

**Why**: raw maxCursorSeen breaks when:
- API returns null cursor values for some records
- Records arrive out of order
- Cursor field is missing from some records
- Creates non-deterministic sync windows
- Replays equal-cursor bursts forever when the source only supports `>= cursor`

Choose the strategy that matches the source:
- bounded window available: `cutoffTime` (required even for JDBC connectors)
- boundary count available: `recordCount`
- boundary count unavailable: `customState.incremental_boundary`

Do not treat extending `BaseJdbcConnector` as a reason to choose `recordCount`. The base
count-at-boundary path is a compatibility fallback for lower-bound-only sources. A JDBC source
whose SQL dialect supports both `cursor >= previousCutoff` and `cursor < currentCutoff` must opt
into the base cutoff-time hook. Its durable `IncrementalField.value` is the current cutoff and its
`recordCount` is null, so the next read never issues `SELECT COUNT(*) ... WHERE cursor = ?`.

Do not manufacture an end cursor for an empty initial baseline. Advancing before any baseline row
is materialized can make the next run behave as an incremental-only change/delete pass. The shared
SDK must suppress that cursor. Connector IT must separately prove:

- empty initial baseline: `endCursorPosition == null`
- empty subsequent incremental window: end cursor equals the supplied cutoff and
  `recordCount == null`

**See**: Phase 5 documentation, Step 2 "Choose the Right Incremental Boundary Strategy"

---

### 10. Not Storing Context for read() in Schema

**DO NOT:**
```java
// Schema creates object but read() doesn't know how to fetch it
ObjectMetadata obj = new ObjectMetadata();
obj.setName("journey");
// No endpoint info stored
return obj;
```

**DO:**
```java
ObjectMetadata obj = new ObjectMetadata();
obj.setName("journey");
obj.putCustomAttribute("api_type", "REST");
obj.putCustomAttribute("api_endpoint", "/interaction/v1/interactions");
return obj;
```

**Why**: read() needs to know how to fetch each object.

---

### 11. Fetching New Token Every Request

**DO NOT:**
```java
private String getAccessToken() {
    // Always fetch new token
    Response response = post(tokenUrl, credentials);
    return response.get("access_token");
}
```

**DO:**
```java
private String accessToken;
private Instant tokenExpiry;

private synchronized String getAccessToken() {
    // Use 5-MINUTE buffer, not 60 seconds (long pagination loops can exceed token lifetime)
    if (accessToken != null && Instant.now().plusSeconds(300).isBefore(tokenExpiry)) {
        return accessToken;  // Use cached token
    }
    // Only fetch when expired
    refreshToken();
    return accessToken;
}
```

**Why**: Token refresh has rate limits and adds latency. Use 5-minute buffer (not 60s) because pagination loops can run 10+ minutes.

---

### 11b. Not Refreshing Token During Pagination Loops

**DO NOT:**
```java
// Get token once at start, paginate forever
String token = getAccessToken();
while (hasMore) {
    response = api.get(url, token);  // Token may expire mid-loop!
    processRecords(response);
}
```

**DO:**
```java
// Refresh token before EACH batch
while (hasMore) {
    tokenManager.ensureValidToken();  // Proactive refresh
    String token = tokenManager.getAccessToken();
    response = api.get(url, token);
    processRecords(response);
}
```

**Why**: OAuth tokens typically expire in 20-60 minutes. Pagination through large datasets can take longer. Token may expire mid-sync causing failures.

---

### 12. Not Setting DatasourceInitResponse Fields

**DO NOT:**
```java
public DatasourceInitResponse init(Map<String, Object> connectionProperties) throws ConnectorException {
    // Just check if API responds
    api.get("/ping");
    return new DatasourceInitResponse();  // Empty response!
}
```

**DO:**
```java
public DatasourceInitResponse init(Map<String, Object> connectionProperties) throws ConnectorException {
    JsonNode info = api.get("/system/info");

    DatasourceInitResponse response = new DatasourceInitResponse();
    response.setSuccess(true);
    response.setDatasourceProductName(getName());
    response.setDatasourceProductVersion(info.get("version").asText());
    return response;
}
```

**Why**: Product info is displayed in the UI and used for diagnostics.

---

### 12b. Syncing High-Volume Objects Without Date Filter

**DO NOT:**
```java
// Sync ALL bounce events from beginning of time (could be millions!)
String url = "/events/bounce";
while (hasMore) {
    response = api.get(url);
    // Processing millions of records...
}
```

**DO:**
```java
// Apply default date filter for high-volume objects
private static final Set<String> HIGH_VOLUME_PATTERNS = Set.of(
    "event", "activity", "log", "tracking", "history", "audit"
);

private String getEffectiveStartDate(String objectName) {
    if (historicalSyncStartDate != null) return historicalSyncStartDate;
    if (isHighVolumeObject(objectName)) {
        return LocalDate.now().minusDays(30).toString();  // 30-day default
    }
    return null;
}
```

**Why**: Marketing/analytics platforms have event tables with millions of records. Full syncs can take hours and overwhelm resources.

---

### 12c. Relying Only on links.next for Pagination

**DO NOT:**
```java
// Trust links.next blindly
hasMore = response.has("links") && response.get("links").has("next");
```

**DO:**
```java
// Count-based check - works for more APIs
int returnedCount = items.size();
hasMore = returnedCount >= pageSize;  // Full page = maybe more
```

**Why**: Some APIs omit `links.next` even when more data exists. Count-based checking is more reliable.

---

## Minor Anti-Patterns (Code Quality)

### 13. Wrong getType() Format

**DO NOT:**
```java
public String getType() {
    return "sfmc";  // lowercase
    return "Sfmc";  // PascalCase
    return "SFMC_Connector";  // Has underscore with lowercase
}
```

**DO:**
```java
public String getType() {
    return "SFMC";  // SCREAMING_SNAKE_CASE
    return "ORACLE_TM";  // Correct
}
```

---

### 14. Committing target/ Directory

**DO NOT:**
```
connectors/supaflow-connector-sfmc/
├── src/
├── target/           # NEVER commit this!
│   └── classes/
└── pom.xml
```

**DO:**
```
# Add to .gitignore BEFORE first commit
target/
```

---

### 15. Not Using PropertyType.BOOLEAN for Booleans

**DO NOT:**
```java
@Property(type = PropertyType.STRING)  // Wrong type!
public String enableFeature = "true";
```

**DO:**
```java
@Property(type = PropertyType.BOOLEAN)
public Boolean enableFeature = true;
```

---

### 16. Accepting Field Selection but Ignoring It (CRITICAL)

**DO NOT:**

```python
def _create_source(..., selected_fields=None, ...):
    return source()  # selected_fields is accepted but ignored
```

```java
for (FieldMetadata field : metadata.getFields()) {
    record.put(field.getName(), extract(item, field)); // emits deselected fields
}
```

**DO:**

- Distinguish no explicit projection (`None`/all `selected=null`) from an
  explicit empty selection.
- Retain only selected output fields plus documented primary-key, cursor,
  deletion, and framework-required fields.
- Push the projection into the vendor request when supported.
- Filter both normalized rows and dlt hints.
- Test a selected field and a known deselected field on initial and
  incremental request shapes.

**Why:** Accepting a selection argument without consuming it looks compatible
in code review but leaks unwanted columns, increases API cost, and can cause
dlt normalize to recreate deselected columns as nulls.

---

### 17. Skipping Essential Reading

**DO NOT:**
- Jump straight to coding without reading core classes
- Copy code from one connector without understanding it
- Guess at class structures

**DO:**
- Read ObjectMetadata.java before implementing schema()
- Read SyncStateRequest.java before implementing read()
- Read RecordProcessor.java to understand lifecycle
- Read reference connectors to see patterns

---

## Quick Verification Checklist

Before submitting, verify these are NOT in your code:

```bash
# Should return NOTHING (processor.close not called)
grep -rn "processor\.close" src/main/java/

# Should return at least one match per object (originalDataType set)
grep -c "setOriginalDataType" src/main/java/**/*.java

# Should return matches (SyncState used)
grep -rn "isInitialSync\|getCursorPosition" src/main/java/

# Should return matches (cursor locked)
grep -rn "setCursorFieldLocked" src/main/java/

# Should return matches (source primary keys set)
grep -rn "setSourcePrimaryKey" src/main/java/

# Should NOT find target/ in git
git ls-files | grep "^target/"

# Python/dlt: selected_fields must be consumed and behaviorally tested
rg -n "selected_fields" python/connectors/supaflow_connector_<name>/connector.py
rg -n "selected_fields_factory|deselected" python/tests -g"*<name>*"
```

---

## Summary Table

| Anti-Pattern | Severity | Check |
|--------------|----------|-------|
| Calling processor.close() | CRITICAL | `grep processor.close` |
| Missing originalDataType | CRITICAL | `grep setOriginalDataType` |
| Ignoring SyncState | CRITICAL | `grep isInitialSync` |
| Not calling identifyCursorFields | CRITICAL | Code review |
| Missing setCursorFieldLocked | CRITICAL | `grep setCursorFieldLocked` |
| Wrong capabilities declared | CRITICAL | Code review |
| No source primary key | CRITICAL | `grep setSourcePrimaryKey` |
| **Hardcoded field parsing** | **CRITICAL** | Schema fields != parsed fields |
| **Using raw maxCursorSeen without a boundary strategy** | **CRITICAL** | `grep maxCursorSeen` |
| Accepting but ignoring field selection | CRITICAL | Sparse initial + incremental read tests |
| Wrong pagination | MODERATE | Manual test |
| Ignoring lookbackTimeSeconds | MODERATE | `grep lookback` |
| No context for read() | MODERATE | Check customAttributes |
| Token fetch every request | MODERATE | Code review |
| Token buffer too small (60s) | MODERATE | Check buffer is 300s (5 min) |
| Not refreshing token in loops | MODERATE | Code review |
| High-volume objects no date filter | MODERATE | Check for event/activity patterns |
| Relying only on links.next | MODERATE | Use count-based check |
| Missing DatasourceInitResponse fields | MODERATE | Code review |
| Wrong getType() format | MINOR | Code review |
| Committing target/ | MINOR | `git ls-files` |
| Wrong PropertyType | MINOR | Code review |
| Skipping essential reading | CRITICAL | Self-assessment |

---

## Destination Connector Anti-Patterns (Phase 7)

### ANTI-PATTERN: Using Instant.now() for Sync Time

**Severity**: CRITICAL

**Problem**: Creates inconsistency between ingestion cutoff time and destination sync time.

```java
// WRONG
@Override
public StageResponse stage(StageRequest request) {
    Instant syncTime = Instant.now();  // Different time than ingestion!
    // Partitions/metadata use wrong timestamp
}
```

**Why It's Wrong**:
- Ingestion captures data up to `cutoffTime`
- If stage() uses `Instant.now()`, timestamps don't match
- `_supa_synced` column will have wrong value
- Partitions (year/month/day/hour) will be inconsistent
- Incremental syncs may skip or duplicate data

**Solution**: Use request.syncTime
```java
// CORRECT
Instant syncTime = request.getSyncTime();
if (syncTime == null) {
    throw new ConnectorException("syncTime is required in StageRequest",
        ConnectorException.ErrorType.VALIDATION_ERROR);
}
```

**Detection**: Code review, verify `stage()` and `load()` use `request.getSyncTime()`

---

### ANTI-PATTERN: Ignoring NamespaceRules in mapToTargetObject()

**Severity**: CRITICAL

**Problem**: Pipeline prefix not applied, destination tables have wrong names.

```java
// WRONG
@Override
public ObjectMetadata mapToTargetObject(ObjectMetadata sourceObj,
                                        NamespaceRules namespaceRules,
                                        ObjectMetadata existingMappedObj) {
    ObjectMetadata dest = new ObjectMetadata();
    dest.setName(sourceObj.getName());  // Missing pipeline prefix!
    return dest;
}
```

**Why It's Wrong**:
- Pipeline prefix is configured by user (e.g., "salesforce_")
- Ignoring NamespaceRules means tables don't have the prefix
- Multiple pipelines from same source will collide
- User expects tables like `salesforce_accounts`, gets `accounts`
- File-based destinations will also lose schema context (path and catalog names collide)

**Solution**: Always apply NamespaceRules
```java
// CORRECT
String targetName = namespaceRules.getTableName(
    keywords, connectorType, quoteString, caseSensitive,
    defaultCatalog, defaultSchema,
    sourceObj.getCatalog(), sourceObj.getSchema(), sourceObj.getName()
);
dest.setName(IdentifierFormatter.formatSnakeCase(targetName));
```

**Detection**: Verify script CHECK 17 (enhanced)

---

### ANTI-PATTERN: Silently Rewriting Destination-Legal Identifiers

**Severity**: CRITICAL

Applying `NamespaceRules` and then stripping leading underscores, adding a letter prefix, or
collapsing unsupported characters without collision handling can route distinct source objects to
one destination object. It also violates `MIRROR_SOURCE`, whose purpose is to preserve legal source
names.

**Solution**:

- Preserve raw source names through discovery.
- Let `NamespaceRules` perform the user-selected transformation.
- Validate each destination identifier class separately.
- Quote legal SQL identifiers instead of sanitizing them merely to avoid quoting.
- Reject invalid/blank resource namespaces, and resolve or reject every collision caused by a
  necessary lossy transformation.

Do not fabricate `_`, `n`, or another placeholder when normalization produces an empty name.
Quoting does not make an invalid dataset/schema/API resource ID legal.

**Detection**: Unit tests with leading digits/underscores, special characters, empty results, and
two distinct inputs that would normalize to the same output; live IT through the production load
format.

---

### ANTI-PATTERN: Adding Tracking Columns in mapToTargetObject()

**Severity**: CRITICAL

**Problem**: Duplicates `_supa_*` columns (writer adds them automatically).

```java
// WRONG
@Override
public ObjectMetadata mapToTargetObject(...) {
    ObjectMetadata dest = new ObjectMetadata();

    // Map source fields
    for (FieldMetadata field : sourceObj.getFields()) {
        dest.addField(field);
    }

    // WRONG - Adding tracking columns manually
    dest.addField(FieldMetadata.builder()
        .name("_supa_synced")
        .canonicalType(CanonicalType.INSTANT)
        .build());
    dest.addField(FieldMetadata.builder()
        .name("_supa_job_id")
        .canonicalType(CanonicalType.STRING)
        .build());

    return dest;
}
```

**Why It's Wrong**:
- Platform's writer/schema mapper adds `_supa_*` columns automatically
- Adding them in `mapToTargetObject()` causes duplicates
- Schema generation fails with "duplicate column" errors
- DDL CREATE TABLE statements have columns twice

**Solution**: Let writer/schema mapper handle tracking columns
```java
// CORRECT - Just map source fields
for (FieldMetadata field : sourceObj.getFields()) {
    FieldMetadata mappedField = mapFieldWithNaming(field);
    dest.addField(mappedField);
}
// Writer automatically adds:
// - _supa_synced (timestamp)
// - _supa_job_id (string)
// - _supa_deleted (boolean)
```

**Detection**: Verify script CHECK 17 (enhanced), code review

---

### ANTI-PATTERN: Wrong CSV File Pattern in stage() or load()

**Severity**: CRITICAL

**Problem**: Looking for `<table>_*.csv` instead of platform's `success_part_*.csv`.

```java
// WRONG
@Override
public StageResponse stage(StageRequest request) {
    String tableName = request.getMetadataMapping()
        .getMappedMergedSourceMetadata().getName();

    // Looking for wrong pattern
    List<Path> csvFiles = Files.walk(localDataPath)
        .filter(p -> p.getFileName().toString().startsWith(tableName + "_"))
        .collect(Collectors.toList());
}
```

**Why It's Wrong**:
- Platform writes: `success_part_0_uuid.csv`, `success_part_1_uuid.csv`, etc.
- Looking for `<table>_*.csv` finds **zero files**
- stage()/load() thinks there's no data, uploads or loads nothing
- load() fails silently (empty staging area)
- Tests pass with simplified names like `test.csv` but production fails

**Solution**: Use correct pattern
```java
// CORRECT
List<Path> csvFiles = Files.walk(localDataPath)
    .filter(Files::isRegularFile)
    .filter(p -> {
        String filename = p.getFileName().toString();
        return filename.startsWith("success_part_") && filename.endsWith(".csv");
    })
    .collect(Collectors.toList());
```

**Detection**: Verify script CHECK 19/20 (enhanced), integration tests

---

### ANTI-PATTERN: Returning a Fake Stage Location for Direct Database Destinations

**Severity**: CRITICAL

**Problem**: Direct JDBC database destinations such as PostgreSQL and SQL Server do not use an external stage. Returning `StageResponse.success("No data to stage")` creates a stage location string and can push `load()` down the wrong code path.

```java
// WRONG for direct database destinations
return StageResponse.success("No data to stage");
```

**Solution**: Return a no-op stage response when no stage exists.

```java
// CORRECT
return StageResponse.noOp("Direct database load - no staging required");
```

**Detection**: Verify script CHECK 19, code review

---

### ANTI-PATTERN: Parsing CSV Without CsvFileFormat

**Severity**: CRITICAL

**Problem**: Parsing CSV files with hardcoded delimiter/quote/header logic instead of the
`CsvFileFormat` passed in `StageRequest.getFileFormat()`.

```java
// WRONG - Hardcoded CSV assumptions
try (CSVReader reader = new CSVReader(new FileReader(csvFile.toFile()))) {
    String[] header = reader.readNext(); // Assumes only 1 header row
}
```

**Why It's Wrong**:
- CursorTracking writes **two header rows** (names + data types)
- Delimiter/quote/escape may be overridden by pipeline config
- Hardcoding causes type rows to be treated as data
- Results in corrupted types and Parquet write failures

**Solution**: Use CsvFileFormat from StageRequest
```java
// CORRECT
CsvFileFormat format = (request.getFileFormat() instanceof CsvFileFormat)
    ? (CsvFileFormat) request.getFileFormat()
    : new CsvFileFormat();

int skipHeader = format.getSkipHeader() != null ? format.getSkipHeader() : 1;
// Configure delimiter/quote/escape from format and skipHeader rows
```

**Detection**: Code review, staging failures with type rows

---

### ANTI-PATTERN: Falling Back to String for Non-String Types

**Severity**: 🟡 HIGH

**Problem**: When parsing CSV values, returning a string for a field that should be numeric/date/time.

```java
// WRONG
try {
    return Long.parseLong(value);
} catch (Exception e) {
    return value; // Wrong for LONG column
}
```

**Why It's Wrong**:
- Parquet expects INT/DOUBLE/TIMESTAMP values for typed columns
- Supplying a string causes writer exceptions (e.g., writeBytes on INT64)
- Data can be silently corrupted if coercion succeeds for some rows

**Solution**: Return null for non-string types when parsing fails
```java
// CORRECT
try {
    return Long.parseLong(value);
} catch (Exception e) {
    return null;
}
```

**Detection**: Parquet write errors, code review

---

### ANTI-PATTERN: Using jobContext.toString() for sync_id

**Severity**: 🟡 HIGH

**Problem**: Gets object reference string or an unrelated random value instead of the pipeline-provided job details ID.

```java
// WRONG
String syncId = runtimeContext.getJobContext().toString();
// Returns: "Job@a1b2c3d4" (object reference, not ID)

// WRONG
String syncId = UUID.randomUUID().toString();
// Returns: Random UUID, not linked to job
```

**Why It's Wrong**:
- `toString()` returns object reference, not the ID field
- Random UUID is not the actual job ID
- The pipeline already passes the correct job details ID on stage/load requests
- Can't track which job wrote which data
- Data lineage is lost
- Debugging sync issues is impossible

**Solution**: Use the request's job details ID
```java
// CORRECT
String syncId = request.getJobDetailsId();
if (syncId == null || syncId.isBlank()) {
    throw new ConnectorException("jobDetailsId is required",
        ConnectorException.ErrorType.VALIDATION_ERROR);
}
```

**Detection**: Code review

---

### ANTI-PATTERN: Simplified IT Test Data

**Severity**: 🟡 HIGH

**Problem**: Tests use simplified patterns that don't catch production issues.

```java
// WRONG - Too simplified
@Test
void testStage() {
    // Create test file with simple name
    Path testFile = testDir.resolve("test_table.csv");
    Files.write(testFile, csvContent);

    // stage() works because it looks for any .csv
    StageResponse response = connector.stage(request);
    assertTrue(response.isSuccess());
}
```

**Why It's Wrong**:
- Test uses `test_table.csv`, production uses `success_part_0_uuid.csv`
- Test passes, production fails (wrong file pattern)
- Doesn't test namespace prefix application
- Doesn't test sync_id propagation
- False confidence in connector implementation

**Solution**: Use realistic patterns
```java
// CORRECT - Match production
@Test
void testStage() {
    // Use production naming convention
    Path successFile = testDir.resolve("success_part_0_12345.csv");
    Files.write(successFile, csvContent);

    // Verify namespace prefix applied
    ObjectMetadata dest = connector.mapToTargetObject(source, namespaceRules, null);
    assertTrue(dest.getName().startsWith(pipelinePrefix),
        "Table name should have pipeline prefix");

    // stage() must find success_part_*.csv
    StageResponse response = connector.stage(request);
    assertTrue(response.isSuccess());
}
```

**Detection**: Code review of IT tests, CHECK 24 (enhanced)

---

### ANTI-PATTERN: Not Preserving customAttributes

**Severity**: 🟡 HIGH

**Problem**: Losing connector-specific context stored in `customAttributes`.

```java
// WRONG
@Override
public ObjectMetadata mapToTargetObject(...) {
    ObjectMetadata dest = new ObjectMetadata();
    dest.setName(targetName);
    dest.setFields(mappedFields);
    // WRONG - Missing customAttributes copy
    return dest;
}
```

**Why It's Wrong**:
- `customAttributes` often holds API endpoints, stream IDs, or other context needed by read/stage/load
- Dropping it can break downstream logic or activation mappings
- Sync metadata should come from `request.getSyncTime()` and Job ID, not customAttributes

**Solution**: Always preserve
```java
// CORRECT
if (sourceObj.getCustomAttributes() != null) {
    dest.setCustomAttributes(new HashMap<>(sourceObj.getCustomAttributes()));
}
```

**Detection**: Code review

---

### ANTI-PATTERN: Propagating Source NOT NULL Into Destination Data Columns

**Severity**: CRITICAL

Source nullability is metadata about the source, not a physical destination constraint. Making
staging or target data columns required breaks sparse hard-delete tombstones, prevents later
nullability relaxation, and makes additive evolution fail on warehouses that forbid adding a
required column to an existing table.

**Solution**: Create physical staging and target data fields as nullable, including source primary
keys, and add new columns as nullable. Preserve any established shared convention for system fields
without deriving data-column constraints from `FieldMetadata.nillable`.

Do not add a migration for physical schemas produced only by an unreleased development revision.
Add compatibility code only for a released or explicitly adopted physical state the connector must
support.

**Detection**: Start with source fields where `nillable=false`; inspect stage and target schemas and
load a sparse tombstone/null through the real path.

---

### ANTI-PATTERN: Merging the Raw Stage Without Deterministic Deduplication

**Severity**: CRITICAL

Passing a raw stage table to `MERGE` allows multiple source rows to match one target identity.
Some warehouses reject the statement; others choose a nondeterministic winner.

Deduplicate by `_supa_id` before `MERGE`. Order descending by selected business cursor fields,
then `_supa_synced`, then `_supa_index`; without cursor fields, use the latter two. Prove both the
generated SQL and the live merge path.

---

### ANTI-PATTERN: Treating System-Field Presence as System-Field Correctness

**Severity**: CRITICAL

Finding `_supa_*` names in metadata does not prove the values agree with other destinations.
Build IT input with the production writer and assert the physical types plus exact values for
`_supa_synced`, `_supa_deleted`, `_supa_index`, `_supa_id`, and `_supa_job_id`. Connector code
must not independently generate or redefine them.

---

### ANTI-PATTERN: Treating Test Setup Tokens as Behavioral Evidence

**Severity**: CRITICAL

Creating a callback list, setting `errorPath`, mentioning `CanonicalType`, or importing
`java.util.concurrent` does not prove callback accounting, error artifacts, an all-types round
trip, or concurrent cold-schema loading. Assert the produced values and destination state through
the real execution path. The verifier intentionally requires those assertions rather than token
presence.

---

### ANTI-PATTERN: Cleaning External Staging Only After Successful Loads

**Severity**: CRITICAL

Success-path prefix cleanup leaves customer data behind when staging, load, or merge fails. Exercise
a failed live load and prove either immediate job-prefix cleanup or the explicitly documented
retained-diagnostics state protected by a short lifecycle rule.

---

### ANTI-PATTERN: Retrying Asynchronous Warehouse Jobs Without Stable Identity

**Severity**: CRITICAL

Submitting a new vendor job after a lost response can duplicate work. Treating
duplicate/already-exists as failure discards a healthy job, while returning a retriable error after
cancelling a deterministic job on timeout can make every platform retry reattach to the cancelled
job.

**Solution**: Use deterministic per-attempt IDs, fetch before submit, attach to duplicate jobs with
bounded visibility polling, recover ambiguous submits under the same ID, and advance attempts only
after a terminal retriable vendor result. Keep quota and retry classifications operation-specific.
Use runtime cancellation in every poller; make connector job timeouts opt-in unless the platform
defines a different default, and report timeout-after-cancel as terminal.

**Detection**: Unit tests for get-first restart, 409/duplicate plus temporary get-not-found,
ambiguous submit, terminal quota, cancellation, and timeout.

---

### ANTI-PATTERN: Creating Customer Resources During Routine Validation

**Severity**: HIGH

Creating a schema/dataset/table or running an upload/load probe from normal `init()` hides
misspelled configuration, leaks resources, consumes job quota on every sync, and can validate a
different normalized name than `load()` actually uses.

**Solution**: Keep routine initialization metadata-only and side-effect-free. Validate required
destination-role settings, the exact target identifiers used by load, resource existence/location,
and error classifications. Run a write probe only in a distinct user-invoked connection-test flow
with cancellation and guaranteed cleanup.

**Detection**: Assert normal init performs no create/upload/load calls and preserves transient,
permission, validation, and cancellation error types.

---

## Destination Anti-Patterns Summary

| Anti-Pattern | Severity | Detection Method |
|-------------|----------|------------------|
| Using Instant.now() for sync time | CRITICAL | Code review |
| Ignoring NamespaceRules | CRITICAL | Verify CHECK 17 |
| Silently rewriting legal identifiers | CRITICAL | Collision tests + production-format live IT |
| Adding tracking columns | CRITICAL | Verify CHECK 17, code review |
| Wrong CSV file pattern | CRITICAL | Verify CHECK 19/20, IT tests |
| Fake stage location for direct DB destination | CRITICAL | Verify CHECK 19 |
| Parsing CSV without CsvFileFormat | CRITICAL | Code review, staging failures |
| String fallback for non-string types | HIGH | Code review, Parquet errors |
| jobContext.toString() for sync_id | HIGH | Code review |
| Simplified IT test data | HIGH | Code review, CHECK 24 |
| Not preserving customAttributes | HIGH | Code review |
| Propagating source NOT NULL | CRITICAL | Required-source metadata + sparse-row live IT |
| Merging a raw, duplicate stage | CRITICAL | SQL unit test + live merge |
| Testing only `_supa_*` field presence | CRITICAL | Exact live schema/value assertions |
| Treating setup tokens as behavioral evidence | CRITICAL | Assertion-level verifier checks |
| Cleaning external staging only on success | CRITICAL | Failure-path live IT |
| Retrying async jobs without stable identity | CRITICAL | Duplicate/ambiguous-submit/timeout tests |
| Creating customer resources during routine validation | HIGH | Side-effect and error-classification tests |

---

## When in Doubt

1. **Read the core class** - Don't guess at structure
2. **Check reference connectors** - See working examples
3. **Run verification script** - Catches many issues
4. **Run IT tests** - Verify with real API
5. **Ask for clarification** - Before making assumptions
