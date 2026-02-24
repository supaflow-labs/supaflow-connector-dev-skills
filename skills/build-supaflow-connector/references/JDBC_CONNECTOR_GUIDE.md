# JDBC Connector Guide

This guide replaces Phases 3-5 for JDBC-based connectors that extend `BaseJdbcConnector`. Use this instead of `PHASE_3_CONNECTION_AUTH.md`, `PHASE_4_SCHEMA_DISCOVERY.md`, and `PHASE_5_READ_OPERATIONS.md`.

Still complete Phase 1 (project setup), Phase 2 (identity/properties), and Phase 6 (integration testing) using their standard docs.

## Essential Reading

Before implementing, read these source files in the platform repo:

- `connectors/supaflow-connector-jdbc-common/.../BaseJdbcConnector.java` -- base class (large file, focus on abstract methods and overridable hooks)
- `connectors/supaflow-connector-postgres/.../PostgresConnector.java` -- reference for source+destination JDBC connector
- `connectors/supaflow-connector-generic-jdbc/.../GenericConnector.java` -- reference for source-only JDBC connector

## What the Base Class Handles (Do NOT Reimplement)

BaseJdbcConnector provides complete implementations for:

| Method | What It Does |
|--------|-------------|
| `init()` | Creates HikariCP DataSource from your `DatasourceConfig`, sets connection pool parameters |
| `read(ReadRequest)` | Executes SELECT with incremental WHERE clauses, cancellation every 1000 records |
| `schema()` | Discovers catalogs, schemas, tables, columns via SchemaCrawler + ResultSetMetaData |
| `identifyCursorFields()` | Auto-detects best cursor fields by name pattern scoring (systemmodstamp, updated_at, etc.) |
| `cancel()` / `heartbeat()` | Statement cancellation via AtomicReference |
| `mapToCanonicalType()` | Maps JDBC SQL type constants to CanonicalType enums |
| `close()` | Shuts down DataSource and connection pool |
| Primary key detection | From JDBC database metadata constraints |

## What You MUST Implement

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

### 2. Source-Only Stub Methods (Required by Interface)

Even if the connector is source-only, the `SupaflowConnector` interface requires these methods. They MUST exist or the class will not compile.

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

## What You MUST Override

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

```java
@Override
public String convertToCanonicalValue(Object value, CanonicalType canonicalType) {
    if (value == null) {
        return CanonicalTypeUtil.NULL_PLACEHOLDER;
    }

    try {
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
- JDBC driver version should be managed in parent POM `<dependencyManagement>`

See `supaflow-connector-postgres/pom.xml` for a complete working example.

## Docker-Based Integration Testing

JDBC connectors typically use Docker containers for integration testing instead of live cloud databases.

### Basic Pattern

```bash
# Start database container
docker run -d --name sqlserver-test \
  -e "ACCEPT_EULA=Y" \
  -e "MSSQL_SA_PASSWORD=YourStr0ngP@ss" \
  -p 1433:1433 \
  mcr.microsoft.com/mssql/mssql-server:2022-latest

# Wait for startup
sleep 15

# Create test database and data
docker exec sqlserver-test /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "YourStr0ngP@ss" -C \
  -Q "CREATE DATABASE testdb; ..."
```

### Common Pitfalls

- **ARM emulation (Apple Silicon)**: Some database features are unavailable under ARM emulation (e.g., SQL Server Full-Text Search). Design test data to avoid these features.
- **Password escaping**: Use passwords without shell-special characters (`!`, `$`, `` ` ``) to avoid escaping issues in Docker commands and sqlcmd.
- **Container persistence**: Docker containers lose data on restart. Create test data in the same script that starts the container, or use volume mounts.
- **Startup time**: Databases need 10-30 seconds to initialize. Add a wait/retry loop before running tests.

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

### Source + Destination (Warehouse)

See `PostgresConnector` for the full destination pattern including `REPLICATION_DESTINATION` capability, load modes, table handling, and schema evolution support.

## Checklist

Before proceeding to Phase 6 (integration testing), verify:

- [ ] Extends `BaseJdbcConnector`
- [ ] `validateAndSetConnectorProperties()` returns correct `DatasourceConfig`
- [ ] `mapTypeByName()` covers all database-specific type names
- [ ] `convertToCanonicalValue()` handles all proprietary JDBC driver Java types
- [ ] `checkForKnownExceptions()` covers auth, SSL, and connection errors
- [ ] Source-only stubs (`mapToTargetObject`, `stage`, `load`) throw `UnsupportedOperationException`
- [ ] POM has JDBC driver as `provided` scope with correct shade excludes
- [ ] Module registered in parent POM `<modules>`
- [ ] Connector compiles: `mvn -pl connectors/supaflow-connector-<name> -DskipTests clean install`
- [ ] Verification script passes: `bash "$SKILL_ROOT/scripts/verify_connector.sh" <name> "$PLATFORM_ROOT"`
