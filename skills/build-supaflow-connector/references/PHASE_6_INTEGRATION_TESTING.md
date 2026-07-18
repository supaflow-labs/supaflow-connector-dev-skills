# Phase 6: Integration Testing

**Objective**: Create comprehensive integration tests that verify connector functionality with real credentials.

**Time Estimate**: 60-90 minutes

**Prerequisite**: Phase 5 completed and all applicable source/shared verification checks pass.

---

## Prerequisites

### Essential Reading

Use mature connectors available in your repo for `<reference-source>` values.

| File | What to Learn | Why It Matters |
|------|---------------|----------------|
| `connectors/supaflow-connector-<reference-source>/src/test/java/.../*ConnectorIT.java` | IT test patterns | Real examples |
| `connectors/supaflow-connector-<reference-source-2>/src/test/java/.../*ConnectorIT.java` | More patterns | Complex connector tests |
| JUnit 5 documentation | Test annotations | @Test, @BeforeAll, @EnabledIf |

### Test Environment Setup

Before writing tests, set up environment variables:

```bash
# Create export.env file (add to .gitignore!)
export {NAME}_CLIENT_ID="your-client-id"
export {NAME}_CLIENT_SECRET="your-client-secret"
export {NAME}_SUBDOMAIN="your-subdomain"
export {NAME}_ACCOUNT_ID="your-account-id"
# Add other required credentials...

# Load before running tests
source export.env
```

---

## Step 1: Create IT Test Class Structure

```java
package io.supaflow.connector.{name};

import io.supaflow.connector.sdk.model.ReadRequest;
import io.supaflow.connector.sdk.model.ReadResponse;
import io.supaflow.connector.sdk.model.SchemaLevel;
import io.supaflow.connector.sdk.model.SchemaRequest;
import io.supaflow.connector.sdk.model.SchemaResponse;
import io.supaflow.connector.sdk.model.SyncStateRequest;
import io.supaflow.connector.sdk.model.SyncStateResponse;
import io.supaflow.connector.sdk.processor.RecordProcessor;
import io.supaflow.connector.sdk.processor.RecordProcessingResult;
import io.supaflow.core.context.ConnectorRuntimeContext;
import io.supaflow.core.enums.CanonicalType;
import io.supaflow.core.enums.ConnectorCapabilities;
import io.supaflow.core.exception.ConnectorException;
import io.supaflow.core.model.datasource.DatasourceInitResponse;
import io.supaflow.core.model.job.IncrementalField;
import io.supaflow.core.model.metadata.FieldMetadata;
import io.supaflow.core.model.metadata.ObjectMetadata;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;
import java.io.IOException;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.*;

/**
 * Integration tests for {Name}Connector.
 *
 * Prerequisites:
 * - Set environment variables: {NAME}_CLIENT_ID, {NAME}_CLIENT_SECRET, etc.
 * - These tests connect to the real API
 *
 * Run with: mvn test -Dtest={Name}ConnectorIT
 */
@EnabledIfEnvironmentVariable(named = "{NAME}_CLIENT_ID", matches = ".+")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
public class {Name}ConnectorIT {

    private static {Name}Connector connector;
    private static List<ObjectMetadata> schema;
    private static Map<String, Object> connectionProps;
    private static DatasourceInitResponse initResponse;

    // ================================================================
    // TEST SETUP
    // ================================================================

    @BeforeAll
    static void setUp() throws ConnectorException {
        connector = new {Name}Connector();

        // Set properties from environment variables
        connectionProps = new HashMap<>();
        connectionProps.put("clientId", System.getenv("{NAME}_CLIENT_ID"));
        connectionProps.put("clientSecret", System.getenv("{NAME}_CLIENT_SECRET"));
        connectionProps.put("subdomain", System.getenv("{NAME}_SUBDOMAIN"));
        connectionProps.put("accountId", System.getenv("{NAME}_ACCOUNT_ID"));

        // Initialize connector
        ConnectorRuntimeContext runtimeContext = createConnectorRuntimeContext();
        connector.setRuntimeContext(runtimeContext);
        initResponse = connector.init(connectionProps);
    }

    @AfterAll
    static void tearDown() throws Exception {
        if (connector != null) {
            connector.close();
        }
    }

    private static ConnectorRuntimeContext createConnectorRuntimeContext() {
        // Create minimal runtime context for testing
        return ConnectorRuntimeContext.createDefault();
    }

    // ================================================================
    // REQUIRED TESTS (10 minimum)
    // ================================================================

    @Test
    @Order(1)
    @DisplayName("Test 1: Connection should succeed with valid credentials")
    void testConnectionSuccess() throws ConnectorException {
        // Act
        DatasourceInitResponse response = initResponse;

        // Assert
        assertThat(response).isNotNull();
        assertThat(response.isSuccess()).isTrue();
        assertThat(response.getDatasourceProductName()).isNotEmpty();
        assertThat(response.getDatasourceProductVersion()).isNotEmpty();

        System.out.println("Connected to: " + response.getDatasourceProductName() +
                           " " + response.getDatasourceProductVersion());
    }

    @Test
    @Order(2)
    @DisplayName("Test 2: Connection should fail with invalid credentials")
    void testConnectionFailure_InvalidCredentials() {
        // Arrange
        {Name}Connector badConnector = new {Name}Connector();
        Map<String, Object> badProps = new HashMap<>(connectionProps);
        badProps.put("clientId", "invalid-client-id");
        badProps.put("clientSecret", "invalid-secret");

        try {
            badConnector.setRuntimeContext(createConnectorRuntimeContext());

            // Act & Assert
            assertThatThrownBy(() -> badConnector.init(badProps))
                .isInstanceOf(ConnectorException.class)
                .satisfies(ex -> assertThat(((ConnectorException) ex).getErrorType())
                    .isEqualTo(ConnectorException.ErrorType.AUTHENTICATION_ERROR));

        } finally {
            try {
                badConnector.close();
            } catch (Exception e) {
                // Ignore cleanup errors
            }
        }
    }

    @Test
    @Order(3)
    @DisplayName("Test 3: Schema discovery should return objects")
    void testSchemaDiscovery() throws ConnectorException {
        // Act
        schema = loadSchema();

        // Assert
        assertThat(schema).isNotNull();
        assertThat(schema).isNotEmpty();

        System.out.println("Discovered " + schema.size() + " objects:");
        for (ObjectMetadata obj : schema) {
            System.out.println("  - " + obj.getName() + " (" + obj.getFields().size() + " fields)");
        }
    }

    @Test
    @Order(4)
    @DisplayName("Test 4: Each object should have required metadata")
    void testObjectMetadataRequirements() throws ConnectorException {
        if (schema == null) {
            schema = loadSchema();
        }

        for (ObjectMetadata obj : schema) {
            // Object requirements
            assertThat(obj.getName())
                .as("Object name should not be null")
                .isNotNull();
            assertThat(obj.getName())
                .as("Object name should not be empty")
                .isNotEmpty();
            assertThat(obj.getFields())
                .as("Object should have fields: " + obj.getName())
                .isNotEmpty();

            // Field requirements
            boolean hasPrimaryKey = false;
            for (FieldMetadata field : obj.getFields()) {
                assertThat(field.getName())
                    .as("Field name should not be null in " + obj.getName())
                    .isNotNull();
                assertThat(field.getCanonicalType())
                    .as("Canonical type required for " + obj.getName() + "." + field.getName())
                    .isNotNull();
                assertThat(field.getOriginalDataType())
                    .as("Original data type required for " + obj.getName() + "." + field.getName())
                    .isNotNull();

                if (Boolean.TRUE.equals(field.getSourcePrimaryKey())) {
                    hasPrimaryKey = true;
                }
            }

            assertThat(hasPrimaryKey)
                .as("Object should have source primary key: " + obj.getName())
                .isTrue();
        }
    }

    @Test
    @Order(5)
    @DisplayName("Test 5: Read should return records for at least one object")
    void testReadReturnsRecords() throws ConnectorException {
        if (schema == null) {
            schema = loadSchema();
        }

        // Find an object to test (prefer one likely to have data)
        ObjectMetadata testObject = findObjectForTest(schema);
        assertThat(testObject).as("Should find an object to test").isNotNull();

        System.out.println("Testing read on: " + testObject.getName());

        // Create record collector
        List<Map<String, Object>> records = new ArrayList<>();
        RecordProcessor processor = new TestRecordProcessor(records, 100);  // Limit to 100

        // Create read request (initial sync)
        ReadRequest request = createReadRequest(testObject, null, processor);

        // Act
        ReadResponse response = connector.read(request);

        // Assert
        assertThat(response).isNotNull();
        System.out.println("Read " + records.size() + " records from " + testObject.getName());

        if (!records.isEmpty()) {
            System.out.println("Sample record: " + records.get(0));
        }
    }

    @Test
    @Order(6)
    @DisplayName("Test 6: Records should have expected fields")
    void testRecordFieldMapping() throws ConnectorException {
        if (schema == null) {
            schema = loadSchema();
        }

        ObjectMetadata testObject = findObjectForTest(schema);
        assertThat(testObject).isNotNull();

        List<Map<String, Object>> records = new ArrayList<>();
        RecordProcessor processor = new TestRecordProcessor(records, 10);

        ReadRequest request = createReadRequest(testObject, null, processor);
        connector.read(request);

        if (!records.isEmpty()) {
            Map<String, Object> record = records.get(0);
            Set<String> schemaFieldNames = testObject.getFields().stream()
                .map(FieldMetadata::getName)
                .collect(Collectors.toSet());
            Set<String> recordFieldNames = record.keySet().stream()
                .filter(name -> name != null && !name.startsWith("_supa_"))
                .collect(Collectors.toSet());

            // Strict enough to catch field-mapping regressions while allowing system metadata columns.
            assertThat(recordFieldNames)
                .as("Record should include all schema fields")
                .containsAll(schemaFieldNames);
        }
    }

    @Test
    @Order(7)
    @DisplayName("Test 7: Reads should honor an explicit field selection")
    void testSelectedFieldProjection() throws ConnectorException {
        if (schema == null) {
            schema = loadSchema();
        }

        ObjectMetadata testObject = findObjectForTest(schema);
        assertThat(testObject).isNotNull();

        Map<String, Boolean> originalSelections = new HashMap<>();
        testObject.getFields().forEach(field ->
            originalSelections.put(field.getName(), field.getSelected()));
        try {
            // Start from an explicit empty projection, then retain operational
            // identity/cursor fields and one ordinary business field.
            testObject.getFields().forEach(field -> field.setSelected(false));
            Set<String> selectedNames = testObject.getFields().stream()
                .filter(field -> field.isPrimaryKey()
                    || Boolean.TRUE.equals(field.getCursorField()))
                .peek(field -> field.setSelected(true))
                .map(FieldMetadata::getName)
                .collect(Collectors.toSet());
            FieldMetadata businessField = testObject.getFields().stream()
                .filter(field -> !selectedNames.contains(field.getName()))
                .findFirst()
                .orElseThrow();
            businessField.setSelected(true);
            selectedNames.add(businessField.getName());

            String deselectedName = testObject.getFields().stream()
                .filter(field -> !selectedNames.contains(field.getName()))
                .map(FieldMetadata::getName)
                .findFirst()
                .orElseThrow();

            List<Map<String, Object>> records = new ArrayList<>();
            connector.read(createReadRequest(
                testObject, null, new TestRecordProcessor(records, 10)));

            if (!records.isEmpty()) {
                Set<String> businessKeys = records.get(0).keySet().stream()
                    .filter(name -> name != null && !name.startsWith("_supa_"))
                    .collect(Collectors.toSet());
                assertThat(businessKeys).containsAll(selectedNames);
                assertThat(businessKeys)
                    .as("Deselected fields must not leak into emitted records")
                    .doesNotContain(deselectedName);
            }
        } finally {
            testObject.getFields().forEach(field ->
                field.setSelected(originalSelections.get(field.getName())));
        }
    }

    @Test
    @Order(8)
    @DisplayName("Test 8: Incremental sync should use cursor position")
    void testIncrementalSync() throws ConnectorException {
        if (schema == null) {
            schema = loadSchema();
        }

        // Find object that supports incremental sync
        ObjectMetadata testObject = null;
        for (ObjectMetadata obj : schema) {
            if (obj.isIncrementalSyncSupported()) {
                testObject = obj;
                break;
            }
        }

        if (testObject == null) {
            System.out.println("No objects support incremental sync, skipping test");
            return;
        }

        System.out.println("Testing incremental sync on: " + testObject.getName());

        // Resolve cursor field from metadata
        String cursorFieldName = testObject.getFields().stream()
            .filter(field -> Boolean.TRUE.equals(field.getCursorField()))
            .map(FieldMetadata::getName)
            .findFirst()
            .orElse(null);
        if (cursorFieldName == null) {
            System.out.println("No cursor field found on object, skipping incremental test");
            return;
        }

        // First sync. The engine supplies cutoffTime even for an initial read.
        List<Map<String, Object>> firstSyncRecords = new ArrayList<>();
        RecordProcessor processor1 = new TestRecordProcessor(firstSyncRecords, 1000);
        OffsetDateTime initialCutoff = OffsetDateTime.now(ZoneOffset.UTC);
        SyncStateRequest initialState = createSyncState(null, initialCutoff, true);
        ReadRequest request1 = createReadRequest(testObject, initialState, processor1);
        ReadResponse response1 = connector.read(request1);

        SyncStateResponse syncState = response1.getSyncState();
        List<IncrementalField> cursorPosition =
            syncState != null ? syncState.getEndCursorPosition() : null;
        System.out.println("First sync: " + firstSyncRecords.size() + " records, cursor: " + cursorPosition);

        if (firstSyncRecords.isEmpty()) {
            assertThat(cursorPosition)
                .as("An empty initial baseline must remain initial")
                .isNull();
            return;
        }

        if (cursorPosition == null || cursorPosition.isEmpty()) {
            fail("A non-empty bounded initial read must return its cutoff cursor");
        }

        String previousCursorValue = cursorPosition.stream()
            .filter(f -> cursorFieldName.equals(f.getFieldName()))
            .map(IncrementalField::getValue)
            .findFirst()
            .orElse(null);
        if (previousCursorValue == null) {
            System.out.println("No cursor value for field " + cursorFieldName + ", skipping incremental test");
            return;
        }

        OffsetDateTime lowerBound;
        try {
            lowerBound = OffsetDateTime.parse(previousCursorValue);
        } catch (Exception e) {
            System.out.println("Cursor is not ISO timestamp, skipping boundary checks: " + previousCursorValue);
            return;
        }

        // Second sync
        List<Map<String, Object>> secondSyncRecords = new ArrayList<>();
        RecordProcessor processor2 = new TestRecordProcessor(secondSyncRecords, 1000);
        OffsetDateTime cutoffTime = OffsetDateTime.now(ZoneOffset.UTC);
        SyncStateRequest syncStateRequest =
            createSyncState(cursorPosition, cutoffTime, false);
        ReadRequest request2 = createReadRequest(testObject, syncStateRequest, processor2);
        ReadResponse response2 = connector.read(request2);

        System.out.println("Second sync: " + secondSyncRecords.size() + " records");

        // Every returned record must be within [previousCursor, cutoffTime)
        for (Map<String, Object> record : secondSyncRecords) {
            Object rawValue = record.get(cursorFieldName);
            assertThat(rawValue)
                .as("Incremental record must include cursor field: " + cursorFieldName)
                .isNotNull();

            OffsetDateTime recordCursor = OffsetDateTime.parse(String.valueOf(rawValue));
            assertThat(recordCursor)
                .as("Incremental lower bound must be inclusive")
                .isGreaterThanOrEqualTo(lowerBound);
            assertThat(recordCursor)
                .as("Incremental upper bound must be exclusive")
                .isBefore(cutoffTime);
        }

        // A subsequent incremental window always advances to its cutoff, including zero rows.
        SyncStateResponse secondSyncState = response2.getSyncState();
        assertThat(secondSyncState).as("Second sync must return sync state").isNotNull();
        List<IncrementalField> endCursor = secondSyncState.getEndCursorPosition();
        assertThat(endCursor).as("Second sync must return end cursor").isNotNull().isNotEmpty();

        String advancedCursorValue = endCursor.stream()
            .filter(f -> cursorFieldName.equals(f.getFieldName()))
            .map(IncrementalField::getValue)
            .findFirst()
            .orElse(null);

        assertThat(advancedCursorValue)
            .as("End cursor must include time-based cursor field: " + cursorFieldName)
            .isNotNull();

        OffsetDateTime advancedCursor = OffsetDateTime.parse(advancedCursorValue);
        FieldMetadata cursorMetadata = testObject.getField(cursorFieldName);
        boolean timeBasedCursor = cursorMetadata != null
            && Set.of(CanonicalType.INSTANT, CanonicalType.LOCALDATETIME, CanonicalType.LOCALDATE)
                .contains(cursorMetadata.getCanonicalType());
        if (timeBasedCursor) {
            assertThat(advancedCursor)
                .as("Bounded time cursor must advance exactly to cutoffTime")
                .isEqualTo(cutoffTime);
            IncrementalField advancedField = endCursor.stream()
                .filter(f -> cursorFieldName.equals(f.getFieldName()))
                .findFirst()
                .orElseThrow();
            assertThat(advancedField.getRecordCount())
                .as("Cutoff cursor must not persist a boundary count")
                .isNull();
        }
    }

    @Test
    @Order(9)
    @DisplayName("Test 9: Connector capabilities should be accurate")
    void testCapabilities() {
        // Act
        Set<ConnectorCapabilities> capabilities = connector.getConnectorCapabilities();

        // Assert
        assertThat(capabilities).isNotNull();

        // Log capabilities
        System.out.println("Connector capabilities:");
        System.out.println("  " + capabilities);
    }

    @Test
    @Order(10)
    @DisplayName("Test 10: Connector identity should be properly set")
    void testConnectorIdentity() {
        // Assert
        assertThat(connector.getType())
            .as("Type should not be null")
            .isNotNull();
        assertThat(connector.getType())
            .as("Type should be uppercase")
            .isEqualTo(connector.getType().toUpperCase());

        assertThat(connector.getName())
            .as("Name should not be null")
            .isNotNull();
        assertThat(connector.getName())
            .as("Name should not be empty")
            .isNotEmpty();

        assertThat(connector.getDescription())
            .as("Description should not be null")
            .isNotNull();

        System.out.println("Connector: " + connector.getType() + " - " + connector.getName());
    }

    // ================================================================
    // HELPER METHODS
    // ================================================================

    private List<ObjectMetadata> loadSchema() throws ConnectorException {
        SchemaRequest request = SchemaRequest.builder()
            .level(SchemaLevel.FULL)
            .build();
        SchemaResponse response = connector.schema(request);
        return response != null ? response.getObjects() : List.of();
    }

    private ObjectMetadata findObjectForTest(List<ObjectMetadata> objects) {
        // Prefer objects likely to have data
        String[] preferredNames = {"journey", "asset", "contact", "subscriber"};

        for (String name : preferredNames) {
            for (ObjectMetadata obj : objects) {
                if (obj.getName().toLowerCase().contains(name)) {
                    return obj;
                }
            }
        }

        // Fall back to first object
        return objects.isEmpty() ? null : objects.get(0);
    }

    private ReadRequest createReadRequest(ObjectMetadata objectMetadata,
                                          SyncStateRequest syncState,
                                          RecordProcessor processor) {
        ReadRequest.Builder builder = ReadRequest.builder()
            .objectMetadata(objectMetadata)
            .recordProcessor(processor);

        if (syncState != null) {
            builder.syncState(syncState);
        }

        return builder.build();
    }

    private SyncStateRequest createSyncState(List<IncrementalField> cursorPosition,
                                             OffsetDateTime cutoffTime,
                                             boolean isInitial) {
        return SyncStateRequest.builder()
            .cursorPosition(cursorPosition)
            .cutoffTime(cutoffTime)
            .initialSync(isInitial)
            .build();
    }

    /**
     * Test implementation of RecordProcessor that collects records.
     */
    private static class TestRecordProcessor implements RecordProcessor {
        private final List<Map<String, Object>> records;
        private final int limit;
        private final RecordProcessingResult result = new RecordProcessingResult();

        TestRecordProcessor(List<Map<String, Object>> records, int limit) {
            this.records = records;
            this.limit = limit;
        }

        @Override
        public boolean processRecord(Map<String, Object> record, List<FieldMetadata> fields) throws IOException {
            if (records.size() < limit) {
                records.add(record);
            }
            return true;
        }

        @Override
        public RecordProcessingResult getResult() {
            return result;
        }

        @Override
        public RecordProcessingResult completeProcessing() {
            result.setRecordCount((long) records.size());
            result.setErrorCount(0L);
            return result;
        }

        @Override
        public void close() {
            // Connector should NOT call this - test will fail if it does
            throw new AssertionError("Connector should not call processor.close()!");
        }
    }
}
```

---

### Incremental Test Oracles (Required)

For at least one incremental object, IT must validate:

1. Lower-bound inclusivity: every incremental record has `cursor >= previousCursor`.
2. Upper-bound exclusivity: every incremental record has `cursor < cutoffTime`.
3. Empty initial suppression: a deterministic empty initial table/object returns zero rows and
   `endCursorPosition == null`, even when the request contains a cutoff.
4. Empty incremental advancement: a deterministic empty subsequent window advances to the
   supplied cutoff.
5. End-state presence: `ReadResponse.syncState.endCursorPosition` is non-null and non-empty after
   subsequent incremental reads.
6. For a bounded time cursor, end state equals the supplied cutoff exactly and has
   `recordCount == null`; the test must not accept a maximum returned record value instead.

Do not satisfy both empty cases with one test or an opportunistic account state. Create an empty
table/object fixture for the initial case and a known no-change half-open window for the subsequent
case. The verifier treats these as separate behavioral contracts.

### Field-Selection Test Oracles (Required)

For at least one object with three or more business fields, IT must validate:

1. One selected non-operational field is present.
2. One known deselected field is absent from every emitted record.
3. Primary-key, cursor, deletion, and framework-owned fields required for a
   valid row remain available.
4. No explicit selection (`selected=null` on every field) preserves the
   connector's full/default projection.
5. The sparse projection works on both the initial and incremental request
   shapes. A source-level fake-client test may cover the incremental request
   when the live account cannot be mutated deterministically.

Do not count the full-schema record-mapping test as field-selection coverage;
it proves completeness, not exclusion.

---

### Destination Connector Handoff Rule

For connectors with `REPLICATION_DESTINATION`, source-style IT is not enough. Complete Phase 7's warehouse or activation destination test matrix before declaring the connector ready for broad source-to-destination smoke tests.

For warehouse destinations, the minimum live IT evidence is:

- All load modes: `APPEND`, `MERGE`, `OVERWRITE`, and `TRUNCATE_AND_LOAD`.
- First-run table handling: `FAIL`, `DROP`, and `MERGE` where supported.
- Callback row counts, `LoadResponse` counts, and error artifact contents.
- Schema evolution DDL beyond column addition, including type changes.
- All-type and binary round trips for the writer format used by the destination.
- Stage file discovery using production `success_part_*` names.
- Identifier behavior through the production writer/stage/load format: quoted legal names,
  invalid/empty namespace rejection, and collision handling after lossy normalization. A standalone
  DDL/DML quoting test is necessary but not sufficient.
- Source metadata with `nillable=false` still produces physically nullable staging and target data
  fields, including additive evolution.
- For asynchronous warehouse APIs: deterministic get-first job recovery, duplicate visibility lag,
  ambiguous submit, operation-scoped quota/retry classification, cancellation, and opt-in timeout
  behavior.
- Routine destination initialization is side-effect-free and validates the same target namespace
  used by load.
- Any destination physical-design preservation required by drop/recreate paths.

Keep credentials in `export.env` and use `@EnabledIfEnvironmentVariable` or assumptions so CI without live credentials skips cleanly.

---

## Step 2: Additional Test Cases (Recommended)

```java
// ================================================================
// OPTIONAL BUT RECOMMENDED TESTS
// ================================================================

@Test
@Order(11)
@DisplayName("Test 11: Pagination should work correctly")
void testPagination() throws ConnectorException {
    if (schema == null) {
        schema = loadSchema();
    }

    ObjectMetadata testObject = findLargeObject(schema);
    if (testObject == null) {
        System.out.println("No large objects found, skipping pagination test");
        return;
    }

    // Collect many records
    List<Map<String, Object>> records = new ArrayList<>();
    RecordProcessor processor = new TestRecordProcessor(records, 500);
    ReadRequest request = createReadRequest(testObject, null, processor);

    ReadResponse response = connector.read(request);

    System.out.println("Pagination test: " + records.size() + " records");

    // If more than one page, pagination is working
    if (records.size() > 50) {
        System.out.println("Pagination working - received more than one page of data");
    }
}

@Test
@Order(12)
@DisplayName("Test 12: Error handling for non-existent object")
void testReadNonExistentObject() {
    // Create fake object metadata
    ObjectMetadata fakeObject = new ObjectMetadata();
    fakeObject.setName("non_existent_object_xyz");
    fakeObject.putCustomAttribute("api_type", "REST");
    fakeObject.putCustomAttribute("api_endpoint", "/v1/nonexistent");

    FieldMetadata field = new FieldMetadata();
    field.setName("id");
    fakeObject.setFields(List.of(field));

    List<Map<String, Object>> records = new ArrayList<>();
    RecordProcessor processor = new TestRecordProcessor(records, 10);
    ReadRequest request = createReadRequest(fakeObject, null, processor);

    // Should throw or handle gracefully
    assertThatThrownBy(() -> connector.read(request))
        .isInstanceOf(ConnectorException.class);
}

@Test
@Order(13)
@DisplayName("Test 13: Historical sync date should limit data")
void testHistoricalSyncDate() throws ConnectorException {
    // Set a recent historical sync date
    String originalDate = connector.historicalSyncStartDate;
    connector.historicalSyncStartDate = "2024-01-01";

    try {
        if (schema == null) {
            schema = loadSchema();
        }

        ObjectMetadata testObject = findObjectForTest(schema);
        if (testObject == null) return;

        List<Map<String, Object>> records = new ArrayList<>();
        RecordProcessor processor = new TestRecordProcessor(records, 1000);
        ReadRequest request = createReadRequest(testObject, null, processor);

        connector.read(request);

        System.out.println("Historical sync from 2024-01-01: " + records.size() + " records");

    } finally {
        // Restore original setting
        connector.historicalSyncStartDate = originalDate;
    }
}

private ObjectMetadata findLargeObject(List<ObjectMetadata> objects) {
    // Find an object likely to have many records
    for (ObjectMetadata obj : objects) {
        if (obj.getName().contains("event") ||
            obj.getName().contains("log") ||
            obj.getName().contains("tracking")) {
            return obj;
        }
    }
    return null;
}
```

---

## Step 3: Run Integration Tests

```bash
# Run from the platform root so reactor dependencies are available
cd <platform-root>

# Load credentials if your repo/task provides an env file
source export.env

# Run all IT tests
mvn -pl connectors/supaflow-connector-{name} -am test -Dtest={Name}ConnectorIT

# Run specific test
mvn -pl connectors/supaflow-connector-{name} -am test -Dtest={Name}ConnectorIT#testConnectionSuccess

# Run with verbose output
mvn -pl connectors/supaflow-connector-{name} -am test -Dtest={Name}ConnectorIT -X
```

---

## Gate Verification

### Expected Test Results

```
[INFO] Results:
[INFO]
[INFO] Tests run: 9, Failures: 0, Errors: 0, Skipped: 0
```

### Verification Script

```bash
# Run final verification
bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>
```

### Expected Output

```
===== CONNECTOR VERIFICATION: {name} =====

CHECK 1:  ✓ RecordProcessor Lifecycle
CHECK 2:  ✓ DatasourceInitResponse Usage
CHECK 3:  ✓ Required Methods Implementation
CHECK 4:  ✓ FieldMetadata Requirements
CHECK 5:  ✓ Connector Capabilities
CHECK 6:  ✓ Property Annotations
CHECK 7:  ✓ Connection Management
CHECK 8:  ✓ Incremental Sync Implementation
CHECK 9:  ✓ Build Configuration
CHECK 10: ✓ OAuth Implementation (or N/A)
CHECK 11: ✓ Naming Conventions
CHECK 12: ✓ Primary Key and Cursor Field Identification
CHECK 13: ✓ Cursor Field Setting Invoked
CHECK 14: ✓ Build Artifacts Not Committed
CHECK 15: ✓ Integration Tests Exist

===== SUMMARY =====
PASSED: 15
FAILED: 0
WARNINGS: 0
```

### Final Checklist

| Check | Status |
|-------|--------|
| ☐ All 9 required IT tests pass | `mvn test` |
| ☐ All 15 verification checks pass | `verify_connector.sh` |
| ☐ `export.env` added to .gitignore | Check .gitignore |
| ☐ No credentials committed | Check git status |
| ☐ Tests documented with @DisplayName | Code review |
| ☐ Tests use @Order for execution sequence | Code review |

---

## Common Mistakes to Avoid

| Mistake | Why It's Wrong | Correct Approach |
|---------|----------------|------------------|
| Committing credentials | Security breach | Use environment variables |
| Missing @EnabledIfEnvironmentVariable | Tests fail in CI without credentials | Skip tests when no credentials |
| Testing with mock data only | Doesn't verify real integration | Use real API |
| No negative test cases | Doesn't verify error handling | Test invalid credentials |
| Ignoring test failures | Bugs ship to production | Fix all failures |
| Not testing incremental sync | Incremental won't work | Verify cursor handling |

---

## Connector Complete!

If all tests pass and all verification checks are green, your connector is complete!

### Final Steps

1. **Documentation**: Update any connector-specific README
2. **Commit**: Stage all files except credentials
3. **Pull Request**: Create PR with test results

### Post-Completion

- Monitor for edge cases after deployment
- Add tests for any bugs discovered
- Consider adding performance tests for large datasets
