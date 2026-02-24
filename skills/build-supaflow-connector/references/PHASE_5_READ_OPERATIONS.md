# Phase 5: Read Operations

**Objective**: Implement read() with proper SyncState handling, incremental sync, pagination, and RecordProcessor lifecycle.

**Time Estimate**: 90-120 minutes

**Prerequisite**: Phase 4 completed and verified.

---

## Prerequisites

### Essential Reading (MUST read before starting)

**CRITICAL**: You MUST read these core classes before implementing read(). This is where most connectors fail.

| File | What to Learn | Why It Matters |
|------|---------------|----------------|
| `supaflow-connector-sdk/.../model/ReadRequest.java` | ReadRequest structure | What inputs you receive |
| `supaflow-connector-sdk/.../model/ReadResponse.java` | ReadResponse structure | What you must return |
| `supaflow-connector-sdk/.../model/SyncStateRequest.java` | SyncStateRequest | **CRITICAL: cutoffTime field** |
| `supaflow-connector-sdk/.../processor/RecordProcessor.java` | RecordProcessor interface | **CRITICAL: Lifecycle** |
| `supaflow-connector-sdk/.../util/CutoffTimeSyncUtils.java` | CutoffTime pattern | **CRITICAL: How to set cursor values** |
| Reference connector read() | Real examples | See complete implementations |

### Find and Read Core Classes

```bash
PLATFORM_ROOT="<platform-root>"
REFERENCE_SOURCE_CONNECTOR="${REFERENCE_SOURCE_CONNECTOR:-oracle-tm}"

# MUST read these files before proceeding
find "$PLATFORM_ROOT" -name "ReadRequest.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "ReadResponse.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "SyncStateRequest.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;
find "$PLATFORM_ROOT" -name "RecordProcessor.java" -path "*/supaflow-connector-sdk/*" -exec cat {} \;

# Read at least one reference connector's read method
grep -A 150 "public ReadResponse read(" \
  "$PLATFORM_ROOT"/connectors/supaflow-connector-"$REFERENCE_SOURCE_CONNECTOR"/src/main/java/**/*.java
```

If no suitable reference connector exists in your repo, rely on this phase guidance and verify cutoffTime/cursor handling with tests before continuing.

### Confirm Understanding

Before proceeding, you MUST be able to answer:

1. What fields does ReadRequest have? (objectMetadata, syncState, filters/customQuery, recordProcessor, callback, continuationToken, etc.)
2. What is SyncStateRequest and how do you get SyncState from it?
3. What does `syncState.isInitialSync()` return and when?
4. What does `syncState.getCursorPosition()` return?
5. **What is `syncState.getCutoffTime()` and why is it CRITICAL for cursor tracking?** (See Section 5.5)
6. What is the RecordProcessor lifecycle? (When to call processRecord, never call close)
7. What fields does ReadResponse have? (status, nextContinuationToken, hasMore, statistics, syncState)

---

## Cancellation in Read Operations (Required)

- Check cancellation in every long-running loop:
  - Pagination loops
  - Per-record processing loops
  - Retry/backoff loops (do NOT retry `CANCELLED`)
- If you sleep for backoff, break it into short chunks and re-check cancellation.
- JDBC connectors must register/clear statements around each query.

---

## Understanding the Read Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        EXECUTOR                                  │
│                                                                  │
│  1. Calls read(request)                                         │
│  2. Expects records via processor.processRecord()               │
│  3. Uses ReadResponse to know if more data exists               │
│  4. Manages RecordProcessor lifecycle (open/close)              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        CONNECTOR                                 │
│                                                                  │
│  1. Extract object metadata and sync state from request         │
│  2. Determine if initial or incremental sync                    │
│  3. Build API query with cursor filter (if incremental)         │
│  4. Fetch data with pagination                                  │
│  5. Call processor.processRecord() for EACH record              │
│  6. Return ReadResponse with hasMore and continuationToken      │
│                                                                  │
│  DO NOT: Close processor, ignore syncState, skip pagination     │
└─────────────────────────────────────────────────────────────────┘
```

### Child/Parent Reads (Associations)

Some API objects are children that require a parent key (e.g., SFMC `campaign_assets` needs `campaignId`). When implementing these:

- **Mark the schema**: set `ObjectMetadata.requiresParentData=true` and `parentObjectName` to the parent table. For activation-style association objects, also set `supaObjectType=ASSOCIATION` if applicable.
- **Persist parent context**: In ingestion, write parent IDs to the job context CSV and include `parent_row_count` in `job_parameters` (V2 uses this to size the child read). Missing parent rows should short-circuit with a clear warning.
- **Fail fast without parent**: In `read()`, if `requiresParentData` is true and no parent IDs are provided, throw a validation error rather than making API calls.
- **Honor parent_row_count**: Log and use the hint to pre-size buffers/batches; it also documents the dependency in logs.
- **Cleanup expectations**: Child jobs may have zero parents; treat that as a no-op (return empty ReadResponse) instead of failure.

---

## Understanding SyncState and CutoffTime

`SyncStateRequest` contains both the previous cursor position AND the `cutoffTime`:

```java
// Getting SyncStateRequest from ReadRequest (canonical accessor)
SyncStateRequest syncState = request.getSyncState();

// Check sync type
boolean isInitialSync = syncState == null || syncState.isInitialSync();

// Get previous cursor position (null on initial sync)
List<IncrementalField> cursorPosition = syncState != null ? syncState.getCursorPosition() : null;

// CRITICAL: Get cutoffTime - this becomes the NEW cursor value
// Use CutoffTimeSyncUtils for formatting:
String cutoffTimeStr = CutoffTimeSyncUtils.formatCutoffTimeIso(syncState);
```

### Initial Sync vs Incremental Sync

| Condition | Sync Type | What to do |
|-----------|-----------|------------|
| `syncState == null` | Initial | Sync ALL data (or from historicalSyncStartDate) |
| `syncState.isInitialSync() == true` | Initial | Sync ALL data |
| `syncState.isInitialSync() == false` | Incremental | Only sync records modified AFTER cursorPosition |

### CutoffTime - The Key to Correct Cursor Handling

| Field | Purpose | Used For |
|-------|---------|----------|
| `cursorPosition` | Previous cursor value | Lower bound of query filter |
| `cutoffTime` | Upper bound for this sync | Upper bound of query filter AND new cursor value |

---

## Understanding RecordProcessor

**CRITICAL**: The executor manages RecordProcessor lifecycle. You MUST:
- Call `processor.processRecord(record)` for each record
- NEVER call `processor.close()` - the executor handles this

```java
// CORRECT - Process each record
for (Map<String, Object> record : records) {
    processor.processRecord(record);
}

// WRONG - Never close the processor!
processor.close();  // DO NOT DO THIS
```

---

## Step 1: Implement Read Method Structure

The `read()` method takes a single `ReadRequest` parameter and returns `ReadResponse`.
Use `CutoffTimeSyncUtils` for cursor handling - it handles all edge cases automatically.

```java
import io.supaflow.connector.sdk.metadata.FilterCondition;
import io.supaflow.connector.sdk.util.CutoffTimeSyncUtils;
import io.supaflow.connector.sdk.util.SyncStateResponseBuilder;
import java.util.stream.Collectors;

@Override
public ReadResponse read(ReadRequest request) throws ConnectorException {

    ObjectMetadata objectMetadata = request.getObjectMetadata();
    String objectName = objectMetadata.getName();
    SyncStateRequest syncState = request.getSyncState();

    log.info("Reading object: {}", objectName);

    try {
        // STEP 1: Get cutoffTime at START - this becomes the new cursor value
        String cutoffTimeStr = CutoffTimeSyncUtils.formatCutoffTimeIso(syncState);

        // STEP 2: Determine sync type for logging/debugging
        boolean isInitialSync = syncState == null || syncState.isInitialSync();
        log.info("Sync type: {}, cutoffTime: {}",
                 isInitialSync ? "INITIAL" : "INCREMENTAL",
                 cutoffTimeStr);

        // STEP 3: Route to appropriate reader based on object type
        String apiType = objectMetadata.getCustomAttributes().get("api_type");
        RecordProcessor processor = request.getRecordProcessor();

        if ("REST".equals(apiType)) {
            readRestObject(objectMetadata, request, processor);
        } else if ("SOAP".equals(apiType)) {
            readSoapObject(objectMetadata, request, processor);
        } else if ("DATA_EXTENSION".equals(apiType)) {
            readDataExtension(objectMetadata, request, processor);
        } else {
            throw new ConnectorException(
                "Unknown API type for object: " + objectName,
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
        }

        // STEP 4: Apply cutoffTime pattern - utility handles ALL cursor logic
        RecordProcessingResult processingResult = processor.completeProcessing();
        processingResult = CutoffTimeSyncUtils.applyCutoffTimeToResult(
            processingResult, request, cutoffTimeStr);

        // STEP 5: Build response using standard builder
        SyncStateResponse syncStateResponse = SyncStateResponseBuilder.fromProcessingResult(
            processingResult, request.getIngestionMode());

        return ReadResponse.builder()
            .status(ReadStatus.COMPLETED)
            .syncState(syncStateResponse)
            .hasMore(false)
            .build();

    } catch (ConnectorException e) {
        throw e;
    } catch (Exception e) {
        log.error("Failed to read object: {}", objectName, e);
        throw new ConnectorException(
            "Failed to read " + objectName + ": " + e.getMessage(), e,
            ConnectorException.ErrorType.DATA_READ_ERROR);
    }
}
```

**Key Points:**
- Single-arg `read(ReadRequest)` - processor is obtained via `request.getRecordProcessor()`
- Get `cutoffTimeStr` at START of method
- Call `CutoffTimeSyncUtils.applyCutoffTimeToResult()` at END - handles all cursor logic
- Use `SyncStateResponseBuilder` to build the sync state response
- No manual cursor tracking needed!

---

## Step 2: Implement Incremental Sync with CutoffTime Pattern

### CRITICAL: Use cutoffTime, NOT maxCursorSeen

**DO NOT** track the maximum cursor value seen in records. This is a common anti-pattern that breaks when:
- API returns null cursor values for some records
- Records arrive out of order
- Cursor field is missing from some records

**INSTEAD**: Use `cutoffTime` from `SyncStateRequest` as both:
1. The upper bound in your query (`WHERE cursor < cutoffTime`)
2. The new cursor value for the next sync

### The CutoffTime Pattern

```
┌──────────────────────────────────────────────────────────────────────┐
│  WRONG: Track maxCursorSeen from records                             │
│  ─────────────────────────────────────────────────────────────────── │
│  Problems:                                                           │
│  • Record may have null cursor value → NPE or cursor goes backward   │
│  • Records arrive out of order → missing data                        │
│  • Non-deterministic sync windows → hard to debug                    │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  CORRECT: Use cutoffTime from SyncStateRequest                       │
│  ─────────────────────────────────────────────────────────────────── │
│  Initial sync:                                                       │
│    Query:  WHERE cursor_field < cutoffTime                           │
│    Result: newCursor = cutoffTime                                    │
│                                                                      │
│  Incremental sync:                                                   │
│    Query:  WHERE cursor_field >= prevCursor AND cursor_field < cutoffTime │
│    Result: newCursor = cutoffTime                                    │
└──────────────────────────────────────────────────────────────────────┘
```

### Implementation using CutoffTimeSyncUtils

The SDK provides `CutoffTimeSyncUtils` which handles all the complexity for you. Your connector just needs to:

1. Get `cutoffTimeStr` at the start
2. Fetch and process records
3. Call `applyCutoffTimeToResult()` at the end

```java
import io.supaflow.connector.sdk.util.CutoffTimeSyncUtils;
import io.supaflow.connector.sdk.util.SyncStateResponseBuilder;

@Override
public ReadResponse read(ReadRequest request) throws ConnectorException {

    ObjectMetadata metadata = request.getObjectMetadata();
    SyncStateRequest syncState = request.getSyncState();
    RecordProcessor processor = request.getRecordProcessor();

    // STEP 1: Get cutoffTime at START - this becomes the new cursor value
    String cutoffTimeStr = CutoffTimeSyncUtils.formatCutoffTimeIso(syncState);

    // STEP 2: Fetch and process records
    fetchAndProcessRecords(metadata, request, processor, cutoffTimeStr);

    // STEP 3: Apply cutoffTime pattern - THIS IS ALL YOU NEED!
    // The utility handles:
    //   - Records with cursor values → replaces with cutoffTime
    //   - Records with null cursor values → creates end fields from cutoffTime
    //   - Zero records → advances cursor appropriately
    RecordProcessingResult result = processor.completeProcessing();
    result = CutoffTimeSyncUtils.applyCutoffTimeToResult(result, request, cutoffTimeStr);

    // STEP 4: Build response using standard builder
    SyncStateResponse syncStateResponse = SyncStateResponseBuilder.fromProcessingResult(
        result, request.getIngestionMode());

    return ReadResponse.builder()
        .status(ReadStatus.COMPLETED)
        .syncState(syncStateResponse)
        .hasMore(false)
        .build();
}

/**
 * Fetch and process records from the API.
 */
private void fetchAndProcessRecords(ObjectMetadata metadata,
                                    ReadRequest request,
                                    RecordProcessor processor,
                                    String cutoffTimeStr) throws ConnectorException {

    String endpoint = metadata.getCustomAttributes().get("api_endpoint");
    String cursorFieldName = CutoffTimeSyncUtils.getCursorFieldName(metadata);

    // Build query URL from SDK-computed time bounds
    String queryUrl = buildQueryUrl(endpoint, request, cursorFieldName, cutoffTimeStr);

    // Paginate through results
    boolean hasMore = true;
    String pageToken = null;

    while (hasMore) {
        checkCancellation("pagination");

        // Refresh token proactively before each batch
        tokenManager.ensureValidToken();

        JsonNode response = fetchPage(queryUrl, pageToken);
        JsonNode items = response.get("items");

        if (items == null || items.isEmpty()) {
            break;
        }

        for (JsonNode item : items) {
            checkCancellation("record processing");
            Map<String, Object> record = extractRecord(item, metadata);

            // Process the record - NO manual cursor tracking needed!
            processor.processRecord(record);
        }

        // Check for more pages
        pageToken = getNextPageToken(response);
        hasMore = pageToken != null;
    }
}

/**
 * Build query URL with time-based filters using cutoffTime.
 *
 * NOTE: This is a simplified example. In production:
 * - URL-encode filter values (especially timestamps with special chars)
 * - Use API-specific page sizes (check API docs for limits)
 * - Consider using a filter builder utility for complex queries
 */
private String buildQueryUrl(String endpoint,
                             ReadRequest request,
                             String cursorFieldName,
                             String cutoffTimeStr) {
    StringBuilder url = new StringBuilder(endpoint);
    url.append("?$pageSize=50");  // Adjust based on API limits

    if (cursorFieldName == null) {
        return url.toString();
    }

    // Let SDK build lower/upper bounds based on syncState + cutoffTime.
    List<FilterCondition> syncFilters = CutoffTimeSyncUtils.buildFiltersWithCutoff(
        request,
        cursorFieldName,
        cutoffTimeStr,
        lookbackTimeSeconds
    );

    if (!syncFilters.isEmpty()) {
        url.append("&$filter=").append(toApiFilter(syncFilters));
    }

    return url.toString();
}

private String toApiFilter(List<FilterCondition> filters) {
    // Convert generic SDK filters to source-specific query syntax.
    // Example output: "modified_at >= '2026-01-01T00:00:00Z' AND modified_at < '2026-01-01T01:00:00Z'"
    return filters.stream()
        .map(this::convertFilter)
        .collect(Collectors.joining(" AND "));
}
```

### Why cutoffTime Works

The `cutoffTime` is set by the executor BEFORE calling `read()`. It represents:
- A point in time that is guaranteed to be in the past
- The upper bound for this sync window
- The starting point for the next sync

```
Timeline:
                          cutoffTime
                              │
  ──────────────────────────────────────────────────►
  │                           │                    │
  previous                    │                  now
  cursor                      │
                              │
  [─────────────────────────►]  ← Data we query
  (previous cursor to cutoff)

                              [────────────────►]  ← Next sync will get this
                              (cutoffTime to next cutoffTime)
```

### Reference Implementation

See `SalesforceTimeBasedSyncUtils` in the Salesforce connector for a production example of this pattern.

---

## Step 3: Extract Records with Proper Type Conversion

```java
/**
 * Extract record from API response, mapping field names and types.
 */
private Map<String, Object> extractRecord(JsonNode item, ObjectMetadata metadata) {
    Map<String, Object> record = new HashMap<>();

    for (FieldMetadata field : metadata.getFields()) {
        String sourcePath = field.getSourcePath();
        String fieldName = field.getName();

        // Get value from JSON using source path
        JsonNode value = getJsonValue(item, sourcePath);

        if (value == null || value.isNull()) {
            record.put(fieldName, null);
            continue;
        }

        // Convert based on canonical type
        Object convertedValue = convertValue(value, field.getCanonicalType());
        record.put(fieldName, convertedValue);
    }

    return record;
}

/**
 * Get value from JSON, supporting nested paths (e.g., "user.email").
 */
private JsonNode getJsonValue(JsonNode root, String path) {
    if (path == null || path.isEmpty()) {
        return null;
    }

    String[] parts = path.split("\\.");
    JsonNode current = root;

    for (String part : parts) {
        if (current == null || !current.has(part)) {
            return null;
        }
        current = current.get(part);
    }

    return current;
}

/**
 * Convert JSON value to appropriate Java type.
 */
private Object convertValue(JsonNode value, CanonicalType type) {
    if (value == null || value.isNull()) {
        return null;
    }

    switch (type) {
        case STRING:
            return value.asText();

        case LONG:
            return value.asLong();

        case DOUBLE:
            return value.asDouble();

        case BOOLEAN:
            return value.asBoolean();

        case INSTANT:
            return parseTimestamp(value.asText());

        case LOCALDATE:
            return LocalDate.parse(value.asText());

        case JSON:
            // Return as string representation
            return value.toString();

        default:
            return value.asText();
    }
}

private Instant parseTimestamp(Object value) {
    if (value == null) {
        return null;
    }

    String str = value.toString();
    try {
        // Try ISO 8601 format
        return Instant.parse(str);
    } catch (Exception e) {
        try {
            // Try other common formats
            DateTimeFormatter formatter = DateTimeFormatter.ofPattern(
                "yyyy-MM-dd'T'HH:mm:ss[.SSS][XXX][X]");
            return Instant.from(formatter.parse(str));
        } catch (Exception e2) {
            log.warn("Failed to parse timestamp: {}", str);
            return null;
        }
    }
}
```

---

## Step 4: Handle Pagination Properly

Different APIs use different pagination patterns:

### Pattern 1: Page-Based Pagination

```java
// API uses $page parameter
int page = 1;
boolean hasMore = true;

while (hasMore) {
    checkCancellation("pagination");
    String url = baseUrl + "&$page=" + page + "&$pageSize=50";
    JsonNode response = restClient.get(url, token);

    processItems(response.get("items"));

    int count = response.get("count").asInt();
    hasMore = (page * 50) < count;
    page++;
}
```

### Pattern 2: Cursor/Offset Pagination

```java
// API uses offset token
String offset = null;
boolean hasMore = true;

while (hasMore) {
    checkCancellation("pagination");
    String url = baseUrl + "&pageSize=100";
    if (offset != null) {
        url += "&offset=" + offset;
    }

    JsonNode response = restClient.get(url, token);
    processItems(response.get("records"));

    // Get next offset from response
    offset = response.has("offset") ? response.get("offset").asText() : null;
    hasMore = offset != null && !offset.isEmpty();
}
```

### Pattern 3: Link-Based Pagination

```java
// API provides next link
String url = baseUrl;
boolean hasMore = true;

while (hasMore) {
    checkCancellation("pagination");
    JsonNode response = restClient.get(url, token);
    processItems(response.get("items"));

    // Check for next link
    JsonNode links = response.get("links");
    if (links != null && links.has("next")) {
        url = links.get("next").asText();
        hasMore = true;
    } else {
        hasMore = false;
    }
}
```

### Retry/Backoff with Cancellation

```java
int retries = 0;
while (retries < maxRetries) {
    try {
        checkCancellation("retry loop");
        return executeApiCall();
    } catch (ConnectorException e) {
        if (e.getErrorType() == ConnectorException.ErrorType.CANCELLED) {
            throw e;  // Never retry cancellation
        }
        if (++retries >= maxRetries) {
            throw e;
        }

        long backoffMs = Math.min(1000L * (1L << retries), 30000L);
        long remaining = backoffMs;
        while (remaining > 0) {
            checkCancellation("backoff sleep");
            long sleepMs = Math.min(remaining, 1000L);
            try {
                Thread.sleep(sleepMs);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                throw new ConnectorException("Operation interrupted", ie,
                        ConnectorException.ErrorType.INTERRUPTED);
            }
            remaining -= sleepMs;
        }
    }
}
throw new ConnectorException("Retry loop exhausted", ConnectorException.ErrorType.CONNECTION_ERROR);
```

---

## Step 5: Build ReadResponse

Use `SyncStateResponseBuilder` to build the response - **DO NOT** manually set cursor position!

```java
import io.supaflow.connector.sdk.util.CutoffTimeSyncUtils;
import io.supaflow.connector.sdk.util.SyncStateResponseBuilder;

// After processing records in read():
RecordProcessingResult processingResult = processor.completeProcessing();

// Apply cutoffTime - this handles ALL cursor logic automatically
processingResult = CutoffTimeSyncUtils.applyCutoffTimeToResult(
    processingResult, request, cutoffTimeStr);

// Build response using standard builder
SyncStateResponse syncStateResponse = SyncStateResponseBuilder.fromProcessingResult(
    processingResult, request.getIngestionMode());

return ReadResponse.builder()
    .status(ReadStatus.COMPLETED)
    .syncState(syncStateResponse)
    .hasMore(false)  // Set true only if using continuation tokens for within-sync pagination
    .build();
```

### Understanding hasMore vs Incremental Sync

| Concept | Purpose | Example |
|---------|---------|---------|
| `hasMore` | More data in current sync | Set to `true` if pagination continues |
| `syncState` | Cursor for next sync | Built from `CutoffTimeSyncUtils` + `SyncStateResponseBuilder` |
| Continuation token | Resume interrupted sync | Page token if sync fails mid-way |

**Important**: Never manually set cursor position. Always use `CutoffTimeSyncUtils.applyCutoffTimeToResult()` followed by `SyncStateResponseBuilder.fromProcessingResult()`.

---

## Step 6: Handle High-Volume Objects

Many marketing/analytics platforms have objects with massive record counts (events, activities, logs). Apply default date filters to prevent overwhelming syncs.

```java
/**
 * Objects with these patterns in their names typically have high volume.
 * Apply default date filters to prevent full-table scans.
 */
private static final Set<String> HIGH_VOLUME_PATTERNS = Set.of(
    "event", "activity", "log", "tracking", "history", "audit"
);

private boolean isHighVolumeObject(String objectName) {
    String lower = objectName.toLowerCase();
    return HIGH_VOLUME_PATTERNS.stream().anyMatch(lower::contains);
}

/**
 * Get effective start date for high-volume objects.
 * If user hasn't set historicalSyncStartDate, default to 30 days for high-volume.
 */
private String getEffectiveStartDate(String objectName) {
    // User-configured date takes precedence
    if (historicalSyncStartDate != null && !historicalSyncStartDate.isEmpty()) {
        return historicalSyncStartDate;
    }

    // Apply 30-day default for high-volume objects
    if (isHighVolumeObject(objectName)) {
        return LocalDate.now().minusDays(30).toString();
    }

    return null;  // Full sync for non-high-volume objects
}
```

**Common high-volume object patterns:**
- HubSpot: `email_events`, `form_submissions`, `engagements`
- Salesforce: `Task`, `Event`, `ActivityHistory`
- Marketing platforms: `BounceEvent`, `OpenEvent`, `ClickEvent`
- Analytics: All event/activity data

---

## Step 7: Handle Different Object Types

When handling different API types (REST, SOAP, custom endpoints), route appropriately but **always use the same CutoffTimeSyncUtils pattern** for cursor handling:

```java
@Override
public ReadResponse read(ReadRequest request) throws ConnectorException {
    ObjectMetadata metadata = request.getObjectMetadata();
    SyncStateRequest syncState = request.getSyncState();

    // Get cutoffTime at START - this will be the new cursor value
    String cutoffTimeStr = CutoffTimeSyncUtils.formatCutoffTimeIso(syncState);

    // Route to appropriate reader based on object type
    String apiType = metadata.getCustomAttributes().get("api_type");

    if ("REST".equals(apiType)) {
        readRestObject(metadata, request, cutoffTimeStr);
    } else if ("SOAP".equals(apiType)) {
        readSoapObject(metadata, request, cutoffTimeStr);
    } else if ("DATA_EXTENSION".equals(apiType)) {
        readDataExtension(metadata, request, cutoffTimeStr);
    }

    // SAME pattern for ALL object types - utility handles everything
    RecordProcessingResult result = request.getRecordProcessor().getResult();
    result = CutoffTimeSyncUtils.applyCutoffTimeToResult(result, request, cutoffTimeStr);

    SyncStateResponse syncStateResponse = SyncStateResponseBuilder.fromProcessingResult(
        result, request.getIngestionMode());

    return ReadResponse.builder()
        .status(ReadStatus.COMPLETED)
        .syncState(syncStateResponse)
        .build();
}
```

**Key Point**: The cursor handling is identical regardless of API type. The `CutoffTimeSyncUtils.applyCutoffTimeToResult()` method handles:
- Records with cursor values → replaces with cutoffTime
- Records with null cursor values → creates end fields from cutoffTime
- Zero records → advances cursor to cutoffTime (for incremental sync)

---

## Step 7: Implement close()

```java
@Override
public void close() throws Exception {
    log.info("Closing {} connector", getName());

    // Clean up resources
    if (httpClient != null) {
        // OkHttpClient doesn't need explicit closing for most cases
        // But if you have connection pools or other resources:
        httpClient.dispatcher().executorService().shutdown();
        httpClient.connectionPool().evictAll();
    }

    // Clear sensitive data
    accessToken = null;
    tokenExpiresAt = null;
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
| CHECK 1 | ✓ RecordProcessor lifecycle (processRecord called, not closed) |
| CHECK 2 | ✓ DatasourceInitResponse usage |
| CHECK 3 | ✓ Required methods implementation |
| CHECK 8 | ✓ Incremental sync implementation |
| All checks | All 15 should pass |

### Manual Checklist

Before proceeding to Phase 6, confirm ALL of the following:

| Check | Verification |
|-------|--------------|
| ☐ read() extracts SyncState from request | Code review |
| ☐ read() checks isInitialSync() | Code review |
| ☐ read() uses cursorPosition for incremental | Code review |
| ☐ read() respects lookbackTimeSeconds | Code review |
| ☐ read() applies historicalSyncStartDate | Code review |
| ☐ processor.processRecord() called for each record | Code review |
| ☐ processor.close() is NEVER called | `grep -n "processor.close"` should find nothing |
| ☐ Pagination handles all pages | Code review |
| ☐ ReadResponse has correct hasMore | Code review |
| ☐ ReadResponse has updated cursor position | Code review |
| ☐ All object types can be read | Test each type |
| ☐ CHECK 1, 2, 3, 8 pass | Verification script |

### Verification Commands

```bash
# Ensure processRecord is called
grep -n "processor.processRecord\|processRecord(" src/main/java/**/*.java

# Ensure processor.close is NOT called (should return nothing)
grep -n "processor.close" src/main/java/**/*.java

# Check for SyncState handling
grep -n "isInitialSync\|getCursorPosition\|SyncState" src/main/java/**/*.java

# Check for lookback handling
grep -n "lookbackTimeSeconds\|lookback\|getLookback" src/main/java/**/*.java
```

### Show Your Work

Before proceeding to Phase 6, show:

1. Output of `mvn compile`
2. Output of `bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>` (ALL 15 checks)
3. Demonstration of read() handling:
   - Initial sync (full data)
   - Incremental sync (filtered by cursor)
4. Confirmation that processor.close() is never called

---

## Common Mistakes to Avoid

| Mistake | Why It's Wrong | Correct Approach |
|---------|----------------|------------------|
| **Calling processor.close()** | Executor manages lifecycle | Never call close |
| **Ignoring SyncState** | Every sync is full sync | Always check isInitialSync/cursorPosition |
| **Ignoring lookbackTimeSeconds** | Misses late-arriving data | Use `CutoffTimeSyncUtils.buildFiltersWithCutoff()` |
| **Tracking maxCursorSeen from records** | Breaks when API returns null cursor values | Use `CutoffTimeSyncUtils.applyCutoffTimeToResult()` |
| **Manually building cursor position** | Error-prone, inconsistent | Use `CutoffTimeSyncUtils` - it handles all cases |
| **Wrong pagination** | Missing data or infinite loops | Match API's actual pagination pattern |
| **Ignoring historicalSyncStartDate** | Syncs too much data | Apply on initial sync |
| **hasMore always false** | Breaks continuation | Set based on actual pagination state |
| **Not handling all object types** | Some objects can't be read | Route by api_type attribute |
| **Hardcoding page size** | May exceed API limits | Use API-appropriate sizes |

---

## Next Phase

Once ALL 15 checks pass, proceed to:
→ **PHASE_6_INTEGRATION_TESTING.md**
