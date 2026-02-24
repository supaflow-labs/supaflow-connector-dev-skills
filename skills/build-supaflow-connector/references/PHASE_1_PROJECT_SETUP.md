# Phase 1: Project Setup

**Objective**: Create a properly structured connector project that compiles successfully.

**Time Estimate**: 15-20 minutes

---

## Prerequisites

### Essential Reading (MUST read before starting)

Before writing any code, you MUST read and understand these files:

Use a mature source connector that exists in your repo for `<reference-source>` (for example, airtable, hubspot, or oracle-tm).

| File | What to Learn | Read Command |
|------|---------------|--------------|
| `connectors/supaflow-connector-<reference-source>/pom.xml` | Maven structure, dependencies, shade plugin | `Read` the file |
| `connectors/supaflow-connector-<reference-source>/src/main/resources/version.properties` | Version file format | `Read` the file |
| `connectors/supaflow-connector-<reference-source>/.gitignore` | What to exclude from git | `Read` the file |

### Confirm Understanding

Before proceeding, you should be able to answer:

1. What is the parent POM groupId and artifactId?
2. What dependencies are typically needed (supaflow-connector-sdk, OkHttp, Jackson)?
3. What does the maven-shade-plugin do?
4. What goes in version.properties?

---

## Step 1: Create Directory Structure

```bash
connectors/supaflow-connector-{name}/
├── pom.xml
├── .gitignore
└── src/
    ├── main/
    │   ├── java/
    │   │   └── io/supaflow/connectors/{name}/
    │   │       └── {Name}Connector.java
    │   └── resources/
    │       └── version.properties
    └── test/
        └── java/
            └── io/supaflow/connectors/{name}/
                └── {Name}ConnectorIT.java
```

**Naming Convention**:
- Directory: `supaflow-connector-{name}` (lowercase, hyphenated)
- Package: `io.supaflow.connectors.{name}` (lowercase)
- Class: `{Name}Connector` (PascalCase)
- Example: `sfmc` → `supaflow-connector-sfmc`, `io.supaflow.connectors.sfmc`, `SfmcConnector`

---

## Step 2: Create pom.xml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <!-- Parent POM - MUST match existing connectors -->
    <parent>
        <groupId>io.supaflow</groupId>
        <artifactId>supaflow-platform</artifactId>
        <version>{platform-version}</version>
        <relativePath>../../pom.xml</relativePath>
    </parent>

    <artifactId>supaflow-connector-{name}</artifactId>
    <packaging>jar</packaging>
    <name>Supaflow Connector - {Display Name}</name>

    <properties>
        <maven.compiler.source>17</maven.compiler.source>
        <maven.compiler.target>17</maven.compiler.target>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    </properties>

    <dependencies>
        <!-- Connector SDK - REQUIRED -->
        <dependency>
            <groupId>io.supaflow</groupId>
            <artifactId>supaflow-connector-sdk</artifactId>
        </dependency>

        <!-- HTTP Client - for REST APIs -->
        <dependency>
            <groupId>com.squareup.okhttp3</groupId>
            <artifactId>okhttp</artifactId>
        </dependency>

        <!-- JSON Processing -->
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>

        <!-- Logging -->
        <dependency>
            <groupId>org.slf4j</groupId>
            <artifactId>slf4j-api</artifactId>
        </dependency>

        <!-- Testing -->
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <!-- Shade plugin - creates fat JAR for deployment -->
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-shade-plugin</artifactId>
                <version>3.5.1</version>
                <executions>
                    <execution>
                        <phase>package</phase>
                        <goals>
                            <goal>shade</goal>
                        </goals>
                        <configuration>
                            <transformers>
                                <transformer implementation="org.apache.maven.plugins.shade.resource.ManifestResourceTransformer">
                                    <mainClass>io.supaflow.connectors.{name}.{Name}Connector</mainClass>
                                </transformer>
                            </transformers>
                            <filters>
                                <filter>
                                    <artifact>*:*</artifact>
                                    <excludes>
                                        <exclude>META-INF/*.SF</exclude>
                                        <exclude>META-INF/*.DSA</exclude>
                                        <exclude>META-INF/*.RSA</exclude>
                                    </excludes>
                                </filter>
                            </filters>
                        </configuration>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

Set `{platform-version}` to the same parent version used by existing connectors in your platform repo.

**Critical Points**:
- Parent POM must be `supaflow-platform`
- `supaflow-connector-sdk` provides core types and SDK helpers
- Shade plugin is REQUIRED for deployment

---

## Step 3: Create version.properties

Location: `src/main/resources/version.properties`

```properties
connector.version=${project.version}
connector.vendor=Supaflow
connector.groupid=${project.groupId}
connector.artifactid=${project.artifactId}
```

**IMPORTANT**:
- Use `connector.vendor=Supaflow` (NOT `io.supaflow`)
- Use Maven variables `${project.*}` for consistency
- The connector name comes from `getName()` method, NOT from properties

---

## Step 4: Create .gitignore

```gitignore
# Build artifacts - NEVER commit these
target/
*.jar
*.class

# IDE files
.idea/
*.iml
.project
.classpath
.settings/

# OS files
.DS_Store
Thumbs.db

# Logs
*.log
```

**CRITICAL**: The `target/` directory must NEVER be committed to git.

---

## Step 5: Create Shell Connector Class

Create the minimum connector class that compiles:

```java
package io.supaflow.connectors.{name};

import io.supaflow.connector.sdk.SupaflowConnector;
import io.supaflow.connector.sdk.metadata.ConnectionProperty;
import io.supaflow.connector.sdk.model.*;
import io.supaflow.connector.sdk.naming.NamespaceRules;
import io.supaflow.connector.sdk.util.IdentifierFormatter;
import io.supaflow.core.context.ConnectorRuntimeContext;
import io.supaflow.core.enums.ConnectorCapabilities;
import io.supaflow.core.enums.ReleaseStage;
import io.supaflow.core.exception.ConnectorException;
import io.supaflow.core.model.datasource.DatasourceInitResponse;
import io.supaflow.core.model.metadata.ObjectMetadata;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.*;

/**
 * {Display Name} Connector
 *
 * Phase 1: Shell implementation - compiles but methods not yet implemented.
 */
public class {Name}Connector implements SupaflowConnector {

    private static final Logger log = LoggerFactory.getLogger({Name}Connector.class);
    private ConnectorRuntimeContext runtimeContext;

    // ================================================================
    // PHASE 2: These will be implemented in Phase 2
    // ================================================================

    @Override
    public List<ConnectionProperty> getProperties() {
        // TODO: Phase 2 - return connection properties
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public String getType() {
        // TODO: Phase 2 - return connector type (e.g., "SFMC")
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public String getName() {
        // TODO: Phase 2 - return display name (e.g., "Salesforce Marketing Cloud")
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public String getDescription() {
        // TODO: Phase 2 - return connector description
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public Set<ConnectorCapabilities> getConnectorCapabilities() {
        // TODO: Phase 2 - return connector capabilities as EnumSet
        // Example: return EnumSet.of(ConnectorCapabilities.REPLICATION_SOURCE);
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public String getVersion() throws ConnectorException {
        // TODO: Phase 2 - load version from version.properties
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public String getIcon() {
        // TODO: Phase 2 - return Base64 encoded SVG icon
        return null;
    }

    @Override
    public String getVendor() throws ConnectorException {
        // TODO: Phase 2 - load vendor from version.properties
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public String getGroupId() throws ConnectorException {
        // TODO: Phase 2 - load groupId from version.properties
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public String getArtifactId() throws ConnectorException {
        // TODO: Phase 2 - load artifactId from version.properties
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public ReleaseStage getReleaseStage() {
        // TODO: Phase 2 - return release stage
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public boolean isIdentifierCaseSensitive() {
        // TODO: Phase 2 - return whether identifiers are case-sensitive
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public Boolean supportsCatalog() {
        // TODO: Phase 2 - return whether connector supports catalogs
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public Boolean supportsMultiCatalog() {
        // TODO: Phase 2 - return whether connector supports multiple catalogs
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public Boolean supportsSchema() {
        // TODO: Phase 2 - return whether connector supports schemas
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public Boolean supportsPackage() {
        // TODO: Phase 2 - return whether connector supports packages
        throw new UnsupportedOperationException("Phase 2: Not yet implemented");
    }

    @Override
    public String getDefaultCatalog() throws ConnectorException {
        // TODO: Phase 2 - return default catalog name
        return null;
    }

    @Override
    public String getDefaultSchema() throws ConnectorException {
        // TODO: Phase 2 - return default schema name
        return null;
    }

    // ================================================================
    // PHASE 3: These will be implemented in Phase 3
    // ================================================================

    @Override
    public void setRuntimeContext(ConnectorRuntimeContext context) {
        // Store runtime context for HTTP client configuration, proxies, etc.
        this.runtimeContext = context;
    }

    @Override
    public DatasourceInitResponse init(Map<String, Object> connectionProperties)
            throws ConnectorException {
        // TODO: Phase 3 - initialize HTTP client, validate config, test connection
        throw new UnsupportedOperationException("Phase 3: Not yet implemented");
    }

    // ================================================================
    // PHASE 4: These will be implemented in Phase 4
    // ================================================================

    @Override
    public SchemaResponse schema(SchemaRequest request) throws ConnectorException {
        // TODO: Phase 4 - discover and return schema
        throw new UnsupportedOperationException("Phase 4: Not yet implemented");
    }

    // ================================================================
    // PHASE 5: These will be implemented in Phase 5
    // ================================================================

    @Override
    public ReadResponse read(ReadRequest request) throws ConnectorException {
        // TODO: Phase 5 - read data with proper SyncState handling
        throw new UnsupportedOperationException("Phase 5: Not yet implemented");
    }

    @Override
    public ValidationResult validateReadRequest(ReadRequest request) {
        // TODO: Phase 5 - validate read request
        throw new UnsupportedOperationException("Phase 5: Not yet implemented");
    }

    @Override
    public void identifyCursorFields(ObjectMetadata objectMetadata) {
        // TODO: Phase 5 - identify best cursor fields for incremental sync
        throw new UnsupportedOperationException("Phase 5: Not yet implemented");
    }

    // ================================================================
    // PHASE 6/7: Destination methods (if applicable)
    // ================================================================

    @Override
    public StageResponse stage(StageRequest request) throws ConnectorException {
        // TODO: Phase 6 - stage data for loading (destination connectors only)
        throw new UnsupportedOperationException("Phase 6: Not yet implemented");
    }

    @Override
    public LoadResponse load(LoadRequest request) throws ConnectorException {
        // TODO: Phase 7 - load data into destination (destination connectors only)
        throw new UnsupportedOperationException("Phase 7: Not yet implemented");
    }

    @Override
    public ObjectMetadata mapToTargetObject(ObjectMetadata sourceObj,
                                           NamespaceRules namespaceRules,
                                           ObjectMetadata existingMappedObj)
            throws ConnectorException {
        // TODO: Phase 7 - map source object to target (destination connectors only)
        throw new UnsupportedOperationException("Phase 7: Not yet implemented");
    }

    // ================================================================
    // Identifier handling methods
    // ================================================================

    // NOTE: Required for destination connectors too (pipeline uses these during mapping).
    @Override
    public String getFullyQualifiedSchemaName(String catalog, String schema,
                                              boolean quoteIdentifiers) {
        // TODO: Phase 4 - return fully qualified schema name
        throw new UnsupportedOperationException("Phase 4: Not yet implemented");
    }

    @Override
    public String getFullyQualifiedTableName(String catalog, String schema,
                                            String tableName, boolean quoteIdentifiers) {
        // TODO: Phase 4 - return fully qualified table name
        throw new UnsupportedOperationException("Phase 4: Not yet implemented");
    }

    @Override
    public String getIdentifierQuoteString() {
        // TODO: Phase 4 - return identifier quote string (e.g., "\"", "`")
        throw new UnsupportedOperationException("Phase 4: Not yet implemented");
    }

    @Override
    public String getIdentifierSeparator() {
        // TODO: Phase 4 - return identifier separator (e.g., ".")
        throw new UnsupportedOperationException("Phase 4: Not yet implemented");
    }

    @Override
    public IdentifierFormatter getIdentifierFormatter() {
        // TODO: Phase 4 - return identifier formatter (required for destinations too)
        throw new UnsupportedOperationException("Phase 4: Not yet implemented");
    }

    // ================================================================
    // Cleanup
    // ================================================================

    @Override
    public void close() throws Exception {
        // TODO: Phase 5 - cleanup resources (HTTP client, connections, etc.)
        log.info("Closing {} connector", getName());
    }
}
```

**Why throw UnsupportedOperationException?**
- Makes it clear which methods are not yet implemented
- Fails fast if accidentally called before implementation
- Documents which phase each method belongs to
- Destination-only connectors may keep read/validate/identifyCursorFields unimplemented, but identifier methods must be implemented before running pipelines.

---

## Step 6: Create Empty IT Test Class

Location: `src/test/java/io/supaflow/connectors/{name}/{Name}ConnectorIT.java`

```java
package io.supaflow.connectors.{name};

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

/**
 * Integration tests for {Name}Connector.
 *
 * Phase 6: Tests will be implemented after connector is complete.
 *
 * Required environment variables:
 * - {NAME}_CLIENT_ID
 * - {NAME}_CLIENT_SECRET
 * - (add other required credentials)
 */
@EnabledIfEnvironmentVariable(named = "{NAME}_CLIENT_ID", matches = ".+")
public class {Name}ConnectorIT {

    @BeforeAll
    static void setup() {
        // TODO: Phase 6 - setup test fixtures
    }

    @Test
    void testConnectionSuccess() {
        // TODO: Phase 6 - implement connection test
    }

    @Test
    void testSchemaDiscovery() {
        // TODO: Phase 6 - implement schema test
    }
}
```

---

## Gate Verification

### Automated Checks

Run these commands and verify they pass:

```bash
# 1. Navigate to connector directory
cd connectors/supaflow-connector-{name}

# 2. Compile the project - MUST succeed
mvn compile

# 3. Run verification script (checks 9 and 14)
cd ../..
bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>
```

### Manual Checklist

Before proceeding to Phase 2, confirm ALL of the following:

| Check | Command/Action | Expected Result |
|-------|----------------|-----------------|
| ☐ Directory exists | `ls connectors/supaflow-connector-{name}` | Directory found |
| ☐ pom.xml valid | `mvn validate` | BUILD SUCCESS |
| ☐ Project compiles | `mvn compile` | BUILD SUCCESS |
| ☐ version.properties exists | `cat src/main/resources/version.properties` | Shows version |
| ☐ .gitignore exists | `cat .gitignore` | Shows target/ excluded |
| ☐ target/ not in git | `git status --ignored` | target/ is ignored |
| ☐ CHECK 9 passes | `verify_connector.sh {name}` | pom.xml + shade plugin ✓ |
| ☐ CHECK 14 passes | `verify_connector.sh {name}` | No target/ in git ✓ |

### Show Your Work

Before proceeding to Phase 2, show:

1. Output of `mvn compile`
2. Output of `bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>` (at least CHECKs 9, 14)
3. Contents of your connector class (showing shell structure)

---

## Common Mistakes to Avoid

| Mistake | Why It's Wrong | Correct Approach |
|---------|----------------|------------------|
| Wrong parent POM | Won't inherit dependencies | Use `supaflow-platform` parent |
| Missing shade plugin | JAR won't deploy correctly | Always include shade plugin |
| Missing supaflow-connector-sdk | Core types/helpers unavailable | Add `supaflow-connector-sdk` dependency |
| Committing target/ | Pollutes repo, causes conflicts | Add to .gitignore FIRST |
| Starting with full implementation | Leads to compilation errors | Build shell first, verify, then implement |

---

## Next Phase

Once all gate checks pass, proceed to:
→ **PHASE_2_CONNECTOR_IDENTITY.md**
