# JDBC Connector Guide

This guide replaces Phases 3-5 for JDBC-based connectors that extend `BaseJdbcConnector`. Use this instead of `PHASE_3_CONNECTION_AUTH.md`, `PHASE_4_SCHEMA_DISCOVERY.md`, and `PHASE_5_READ_OPERATIONS.md`.

Still complete Phase 1 (project setup), Phase 2 (identity/properties), and Phase 6 (integration testing) using their standard docs. If the JDBC connector is also a destination, complete Phase 7 after this guide.

## Essential Reading

Before implementing, read these source files in the platform repo:

- `connectors/supaflow-connector-jdbc-common/.../BaseJdbcConnector.java` -- base class (large file, focus on abstract methods and overridable hooks)
- `connectors/supaflow-connector-postgres/.../PostgresConnector.java` -- reference for source+destination JDBC connector, including direct destination loading
- `connectors/supaflow-connector-generic-jdbc/.../GenericConnector.java` -- reference for source-only JDBC connector

## What the Base Class Handles (Do NOT Reimplement)

BaseJdbcConnector provides complete implementations for:

| Method | What It Does |
|--------|-------------|
| `init()` | Creates HikariCP DataSource from your `DatasourceConfig`, sets connection pool parameters |
| `read(ReadRequest)` | Executes SELECT with incremental WHERE clauses, cancellation every 1000 records; count-based state is the compatibility fallback unless the connector opts into cutoff windows |
| `schema()` | Discovers catalogs, schemas, tables, columns via SchemaCrawler + ResultSetMetaData |
| `identifyCursorFields()` | Auto-detects best cursor fields by name pattern scoring (systemmodstamp, updated_at, etc.) |
| `cancel()` / `heartbeat()` | Statement cancellation via AtomicReference |
| `mapToCanonicalType()` | Maps JDBC SQL type constants to CanonicalType enums |
| `close()` | Shuts down DataSource and connection pool |
| Primary key detection | From JDBC database metadata constraints |

## Required Incremental Boundary Decision

Extending `BaseJdbcConnector` does not decide the cursor strategy. Before accepting the inherited
read behavior, classify the source:

1. **Time cursor and reliable upper bound available**: use cutoff time. Databases that can execute
   `cursor >= previousCutoff AND cursor < currentCutoff` are in this category.
2. **No reliable upper bound, but exact boundary count available**: use the inherited
   `recordCount` fallback.
3. **Neither upper bound nor count available**: use connector-owned boundary dedup state rather
   than raw maximum-value advancement.

For category 1, override the base opt-in hook:

```java
@Override
protected boolean useCutoffTimeForTimeBasedCursors() {
    return true;
}
```

The base cutoff path then:

- Leaves an initial read unbounded so rows with a null cursor are captured.
- Executes incremental reads as the half-open window
  `[previousCutoff, currentCutoff)`.
- Persists `IncrementalField.value = currentCutoff`.
- Leaves `IncrementalField.recordCount` and `maxValueSeen` null; advancement does not depend on
  result values or a separate `COUNT(*)` query.
- Advances an empty incremental window to the current cutoff.
- Preserves empty state for an empty initial baseline.

Treat those last two cases as different invariants:

| Request | Rows | Required end state |
|---------|------|--------------------|
| Initial baseline | `> 0` | supplied cutoff, `recordCount == null` |
| Initial baseline | `0` | no end cursor; bootstrap remains initial |
| Subsequent incremental | `> 0` | supplied cutoff, `recordCount == null` |
| Subsequent incremental | `0` | supplied cutoff, `recordCount == null` |

The shared SDK owns the empty-initial suppression. Do not compensate in connector-specific
`read()` code. Add live connector tests for both empty cases because a non-empty baseline cannot
prove the bootstrap invariant.

Override `formatCutoffTimeForCursor(...)` only when the database requires connector-specific
precision or literal formatting. Keep connector-specific prepared-parameter handling in
`bindPlaceholder(...)` and `bindValue(...)`.

Do not copy the inherited count-at-boundary behavior into a new warehouse connector merely
because older PostgreSQL, Snowflake, or SQL Server paths still use it. The count path is a fallback,
not the preferred JDBC pattern.

## What You MUST Implement For Every JDBC Connector

### 1. `validateAndSetConnectorProperties()` (Abstract -- Required)

The only abstract method. Called during `init()` to build the `DatasourceConfig` that creates the connection pool.

```java
@Override
protected DatasourceConfig validateAndSetConnectorProperties(
        Map<String, Object> connectionProperties) throws ConnectorException {

    // 1. Extract and validate properties
    String host = (String) validateOrThrow(connectionProperties, "host");
    String port = String.valueOf(validateOrThrow(connectionProperties, "port"));
    String database = (String) validateOrThrow(connectionProperties, "database");
    String username = (String) validateOrThrow(connectionProperties, "username");
    String password = (String) connectionProperties.get("password");
    String noopQuery = (String) connectionProperties.getOrDefault("noopQuery", "SELECT 1");

    // 1.1 Security defaults (recommended)
    String encrypt = (String) connectionProperties.getOrDefault("encrypt", "true");
    String trustServerCertificate =
        (String) connectionProperties.getOrDefault("trustServerCertificate", "false");

    // 2. Build JDBC URL
    String jdbcUrl = String.format(
        "jdbc:sqlserver://%s:%s;databaseName=%s;encrypt=%s;trustServerCertificate=%s",
        host, port, database, encrypt, trustServerCertificate);

    // 3. Return DatasourceConfig
    Properties additionalProps = new Properties();
    return new DatasourceConfig(
        "com.microsoft.sqlserver.jdbc.SQLServerDriver",  // driver class
        jdbcUrl,
        username,
        password,
        noopQuery,
        additionalProps  // Map<String, String> of driver-specific properties
    );
}
```

### 2. Destination Methods: Choose Source-Only Stubs or Real Destination Implementations

The `SupaflowConnector` interface requires `mapToTargetObject`, `stage`, and `load` for every connector class. What these methods do depends on the connector's declared capabilities.

#### Source-Only JDBC Connectors

If `getConnectorCapabilities()` returns only `REPLICATION_SOURCE`, implement source-only stubs. Throw `UnsupportedOperationException` or `ConnectorException` with `UNSUPPORTED_OPERATION`.

```java
@Override
public ObjectMetadata mapToTargetObject(ObjectMetadata sourceObj,
        NamespaceRules namespaceRules, ObjectMetadata existingMappedObj)
        throws ConnectorException {
    throw new UnsupportedOperationException("Source-only connector");
}

@Override
public StageResponse stage(StageRequest request) throws ConnectorException {
    throw new UnsupportedOperationException("Source-only connector");
}

@Override
public LoadResponse load(LoadRequest request) throws ConnectorException {
    throw new UnsupportedOperationException("Source-only connector");
}
```

#### JDBC Source + Destination Connectors

If the connector should also be a destination, do not use the stubs above. Add `REPLICATION_DESTINATION` and implement Phase 7 using `PostgresConnector` as the reference pattern:

- `stage()` returns `StageResponse.noOp(...)` because direct database destinations load from `LoadRequest.getLocalDataPath()`.
- `load()` handles `request.isDdlOnly()` and `request.isZeroRows()` before requiring `localDataPath`.
- `load()` discovers `success_part_*.csv` files from `request.getLocalDataPath()` and ignores error files.
- `load()` creates an in-database staging table, bulk-loads local CSV data, updates tracking columns with `request.getSyncTime()` and `request.getJobDetailsId()`, then executes the requested load mode.
- Keep `executeSqlScript()` inherited from `BaseJdbcConnector` unless the database needs connector-specific script behavior.

For SQL Server destination support, model the implementation on Postgres but adapt the dialect: SQL Server identifiers, native type mapping, bulk-load API, staging-table DDL, `MERGE` syntax, and schema-evolution SQL.

### JDBC Identifier Formatting Notes

`BaseJdbcConnector` already provides `getIdentifierFormatter()`, `getFullyQualifiedSchemaName(...)`, and `getFullyQualifiedTableName(...)` using the connector's quote string, separator, catalog/schema support, and case-sensitivity settings. For JDBC destinations, read those inherited methods before adding Phase 7 mapping code.

Connector-specific destination code should:
- Reuse inherited FQN/formatter methods instead of hand-concatenating catalog/schema/table names.
- Override or configure only database-specific pieces such as quote string (`"` vs `[]`), separator, catalog/schema support, and identifier case sensitivity.
- Follow `PostgresConnector.mapToTargetObject(...)` as the direct database reference, then swap in the connector's own data type mapper and dialect helpers.

## What You MUST Override For Source Correctness

### 3. `mapTypeByName()` (Override -- Required for Correctness)

Maps database-specific type names to CanonicalType. Called before JDBC type constant mapping, so this is your chance to handle types that the standard JDBC mapping gets wrong.

```java
@Override
protected CanonicalType mapTypeByName(String typeName) {
    // Database-specific types that JDBC type constants don't handle well
    switch (typeName.toLowerCase()) {
        // Types mapped to STRING
        case "uniqueidentifier":
        case "hierarchyid":
        case "sql_variant":
        case "sysname":
            return CanonicalType.STRING;

        // Monetary types -> BIGDECIMAL (not DOUBLE)
        case "money":
        case "smallmoney":
            return CanonicalType.BIGDECIMAL;

        // Datetime types
        case "datetime":
        case "datetime2":
        case "smalldatetime":
            return CanonicalType.LOCALDATETIME;
        case "datetimeoffset":
            return CanonicalType.INSTANT;

        // Spatial types -> STRING (serialized)
        case "geometry":
        case "geography":
            return CanonicalType.STRING;

        // JSON types
        case "json":
        case "jsonb":
            return CanonicalType.JSON;

        // XML types
        case "xml":
            return CanonicalType.XML;

        default:
            // Falls through to base class JDBC type constant mapping
            return super.mapTypeByName(typeName);
    }
}
```

### 4. `convertToCanonicalValue()` (Override -- CRITICAL)

Converts raw Java objects from the JDBC ResultSet into canonical string values. Without this override, the base class uses generic conversion which will throw `ClassCastException` for proprietary driver types.

Every JDBC driver returns proprietary Java objects for database-specific types:
- **SQL Server**: `microsoft.sql.DateTimeOffset`, `com.microsoft.sqlserver.jdbc.Geometry`
- **PostgreSQL**: `org.postgresql.util.PGobject`, `org.postgresql.jdbc.PgArray`
- **Oracle**: `oracle.sql.TIMESTAMP`, `oracle.sql.STRUCT`
- **BigQuery and other warehouses**: native JSON may be returned as ordinary text; arrays and
  structs may arrive as `Array`, `Struct`, maps, or driver-specific wrappers

```java
@Override
public String convertToCanonicalValue(Object value, CanonicalType canonicalType) {
    if (value == null) {
        return CanonicalTypeUtil.NULL_PLACEHOLDER;
    }

    try {
        // Preserve JSON semantics when the driver returns native JSON as text.
        if (canonicalType == CanonicalType.JSON && value instanceof CharSequence text) {
            return JSON.writeValueAsString(JSON.readTree(text.toString()));
        }

        // Handle driver-specific types by checking the package prefix
        if (value.getClass().getName().startsWith("com.microsoft.sqlserver.")) {
            // DateTimeOffset -> ISO-8601 string
            if (value.getClass().getSimpleName().equals("DateTimeOffset")) {
                return value.toString();  // microsoft.sql.DateTimeOffset.toString() produces ISO format
            }
            // Geometry/Geography -> WKT string
            if (value.getClass().getSimpleName().equals("Geometry") ||
                value.getClass().getSimpleName().equals("Geography")) {
                return value.toString();
            }
        }

        // Standard JDBC types handled by parent
        return super.convertToCanonicalValue(value, canonicalType);
    } catch (Exception e) {
        log.warn("Conversion failed for {} of type {}: {}",
                 value, canonicalType, e.getMessage(), e);
        return value.toString();  // Last resort fallback
    }
}
```

**Why this matters**: The base class calls `CanonicalTypeUtil.convertToCanonicalValue()` which expects standard Java types (`String`, `BigDecimal`, `Timestamp`, etc.). When the JDBC driver returns `microsoft.sql.DateTimeOffset` instead of `java.sql.Timestamp`, the utility method does not know how to handle it and throws an exception. Your override intercepts these proprietary types before they reach the utility.

Do not stop at class-package checks. Conversion is a two-dimensional contract:

1. source canonical type (`JSON`, `BINARY`, `INSTANT`, and so on)
2. actual runtime value shape returned by the selected driver

Use a credential-gated all-types readback test to exercise the real driver. For JSON, compare
parsed JSON trees so an object, array, number, boolean, or null cannot silently become a quoted
string. For arrays/structs, preserve element order and field names when the canonical output is
JSON; document any unsupported nested destination shape separately.

## What You SHOULD Override

### 5. `checkForKnownExceptions()` (Recommended)

Provides user-friendly error messages for common connection failures. Without this, users see raw JDBC stack traces.

```java
@Override
public ConnectorException checkForKnownExceptions(Throwable e) {
    String msg = e.getMessage() != null ? e.getMessage().toLowerCase() : "";

    if (msg.contains("login failed")) {
        return new ConnectorException(
            "Authentication failed. Check username and password.",
            e, ConnectorException.ErrorType.VALIDATION_ERROR);
    }
    if (msg.contains("cannot open server") || msg.contains("connection refused")) {
        return new ConnectorException(
            "Cannot connect to server. Check host, port, and firewall rules.",
            e, ConnectorException.ErrorType.RETRIABLE_ERROR);
    }
    if (msg.contains("ssl") || msg.contains("tls") || msg.contains("certificate")) {
        return new ConnectorException(
            "SSL/TLS error. Check encrypt and trustServerCertificate settings.",
            e, ConnectorException.ErrorType.VALIDATION_ERROR);
    }

    return super.checkForKnownExceptions(e);
}
```

### 6. `isRetryableException(SQLException)` for JDBC Destinations (Required Review)

`BaseJdbcConnector` retries broad SQLState classes for transient connection, transaction, and resource failures. That is useful for sources, but warehouse destinations often return the same broad class for terminal conditions that should not be retried.

If the connector is a destination, review destination-specific errors and override `isRetryableException(SQLException)` when needed:

```java
@Override
protected boolean isRetryableException(SQLException e) {
    if (isWarehouseUsageLimit(e) || isStatementTimeout(e) || isUserCancellation(e)) {
        return false;
    }
    return super.isRetryableException(e);
}
```

Add unit tests for both sides:

- A terminal destination error is not retryable.
- A transient connection/serialization error remains retryable.
- A concurrent cold-schema/table creation conflict remains retryable or is prevented with serialized/idempotent DDL.

Do this before live smoke testing. A retry loop around a non-retryable warehouse error can hide the real root cause and waste capacity.

## POM Pattern for JDBC Connectors

```xml
<dependencies>
    <!-- JDBC common base class (compile scope) -->
    <dependency>
        <groupId>io.supaflow</groupId>
        <artifactId>supaflow-connector-jdbc-common</artifactId>
        <version>${project.version}</version>
    </dependency>

    <!-- Database JDBC driver (provided - agent supplies at runtime) -->
    <dependency>
        <groupId>com.microsoft.sqlserver</groupId>
        <artifactId>mssql-jdbc</artifactId>
        <scope>provided</scope>
    </dependency>
</dependencies>
```

Key POM requirements:
- JDBC driver must be `scope=provided` (not bundled in shade JAR)
- Shade plugin must exclude the JDBC driver: `<exclude>com.microsoft.sqlserver:*</exclude>`
- `copy-provided-dependencies` execution must copy the driver to `jars/` subdirectory
- Java connectors must include the local-agent deployment execution used by mature connectors (`exec-maven-plugin` with `deploy-local-connector`)
- JDBC driver version should be managed in parent POM `<dependencyManagement>`

See `supaflow-connector-postgres/pom.xml` for a complete working example.

## Docker-Based Integration Testing

JDBC connectors typically use Docker containers for integration testing instead of live cloud databases.

### Basic Pattern

```bash
# Start database container
docker run -d --name sqlserver-test \
  --platform linux/amd64 \
  -e "ACCEPT_EULA=Y" \
  -e "MSSQL_SA_PASSWORD=YourStr0ngP@ss" \
  -p 1433:1433 \
  mcr.microsoft.com/mssql/server:2022-latest

# Wait for startup
sleep 15

# Create test database and data
docker exec sqlserver-test /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "YourStr0ngP@ss" -C \
  -Q "CREATE DATABASE testdb; ..."
```

### Common Pitfalls

- **SQL Server image name**: Use `mcr.microsoft.com/mssql/server:2022-latest`, not the stale `mcr.microsoft.com/mssql/mssql-server` path.
- **ARM emulation (Apple Silicon)**: SQL Server images are amd64-only; use `--platform linux/amd64` on arm64 machines. Some database features are unavailable under emulation (e.g., SQL Server Full-Text Search). Design test data to avoid these features.
- **Password escaping**: Use passwords without shell-special characters (`!`, `$`, `` ` ``) to avoid escaping issues in Docker commands and sqlcmd.
- **Container persistence**: Docker containers lose data on restart. Create test data in the same script that starts the container, or use volume mounts.
- **Startup time**: Databases need 10-30 seconds to initialize. Add a wait/retry loop before running tests.
- **Driver-native bulk APIs**: Pooled connections may be Hikari proxy objects. Before passing a connection to driver-native bulk loaders such as `SQLServerBulkCopy`, unwrap it to the vendor connection class with `connection.unwrap(...)`.

### IT Test Environment Variables

```bash
export SQLSERVER_HOST=localhost
export SQLSERVER_PORT=1433
export SQLSERVER_DATABASE=testdb
export SQLSERVER_USERNAME=sa
export SQLSERVER_PASSWORD=YourStr0ngP@ss
```

Use `@EnabledIfEnvironmentVariable` in JUnit 5 to skip IT tests when credentials are not set.

## Capabilities for JDBC Connectors

### Source-Only

```java
@Override
public Set<ConnectorCapabilities> getConnectorCapabilities() {
    return EnumSet.of(ConnectorCapabilities.REPLICATION_SOURCE);
}

@Override
public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
    return ConnectorCapabilitiesConfigBuilder.builder()
        .requiresStaging(false)
        .requiresExplicitLoadStep(false)
        .build();
}
```

### Source + Destination (Direct Database)

```java
@Override
public Set<ConnectorCapabilities> getConnectorCapabilities() {
    return EnumSet.of(
        ConnectorCapabilities.REPLICATION_SOURCE,
        ConnectorCapabilities.REPLICATION_DESTINATION
    );
}

@Override
public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
    return ConnectorCapabilitiesConfigBuilder.builder()
        .asTraditionalDatabase()
        .requiresStaging(false)
        .requiresExplicitLoadStep(true)
        .canAutoCreateSchema(true)
        .supportsHardDeletes(true)
        // Include the null marker only if the load implementation supports it.
        // Postgres uses "\\N"; SQL Server should use the marker its loader handles.
        .supportedNullIf(List.of("\\N"))
        .build();
}
```

See `PostgresConnector` for the full direct database destination pattern including `REPLICATION_DESTINATION`, no-op staging, local CSV loading, load modes, table handling, and schema evolution support.

## Checklist

Before proceeding to Phase 6 (integration testing), verify:

- [ ] Extends `BaseJdbcConnector`
- [ ] `validateAndSetConnectorProperties()` returns correct `DatasourceConfig`
- [ ] Time-based cursor strategy is classified; connectors with a reliable SQL upper bound override `useCutoffTimeForTimeBasedCursors()` and do not persist boundary counts
- [ ] Live cutoff IT proves an empty initial baseline has no end cursor and an empty subsequent incremental window advances exactly to cutoff
- [ ] `mapTypeByName()` covers all database-specific type names
- [ ] `convertToCanonicalValue()` handles driver Java types plus canonical JSON/binary/temporal semantics
- [ ] `checkForKnownExceptions()` covers auth, SSL, and connection errors
- [ ] If source-only: stubs (`mapToTargetObject`, `stage`, `load`) throw `UnsupportedOperationException` or `UNSUPPORTED_OPERATION`
- [ ] If source+destination: `getConnectorCapabilities()` includes `REPLICATION_DESTINATION`
- [ ] If source+destination: `stage()` returns `StageResponse.noOp(...)`, not a fake stage location
- [ ] If source+destination: `load()` reads `LoadRequest.getLocalDataPath()`, handles DDL-only/zero-rows, and uses `request.getSyncTime()` plus `request.getJobDetailsId()`
- [ ] POM has JDBC driver as `provided` scope with correct shade excludes
- [ ] Destination connectors review/override `isRetryableException(SQLException)` and test terminal-error exclusions
- [ ] Destination connectors cover concurrent first-load objects into a brand-new schema
- [ ] POM includes `deploy-local-connector` so local agent runs pick up the built connector
- [ ] Module registered in parent POM `<modules>`
- [ ] Connector compiles from the platform root: `mvn -pl connectors/supaflow-connector-<name> -am -DskipTests clean install`
- [ ] Verification script passes: `bash "$SKILL_ROOT/scripts/verify_connector.sh" <name> "$PLATFORM_ROOT"`
