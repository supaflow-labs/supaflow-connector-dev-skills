# Phase 2: Connector Identity & Properties

**Objective**: Define connector identity (type, name, icon), connection properties, and capabilities.

**Time Estimate**: 30-45 minutes

**Prerequisite**: Phase 1 completed and verified.

---

## Prerequisites

### Essential Reading (MUST read before starting)

| File | What to Learn | Why It Matters |
|------|---------------|----------------|
| `supaflow-connector-sdk/.../SupaflowConnector.java` | Connector interface | Understand the contract |
| `supaflow-core/.../enums/ConnectorCapabilities.java` | Capabilities enum | What capabilities to declare |
| `supaflow-connector-sdk/.../annotation/Property.java` | Property annotation | How to define properties |
| `supaflow-connector-sdk/.../metadata/PropertyType.java` | Property types | STRING, BOOLEAN, ENUM, OAUTH_CONFIG, etc. |
| Reference connector properties | Real examples | See how properties are defined |

### Find Core Classes

```bash
# Find the core classes to read
find . -name "SupaflowConnector.java" -path "*/supaflow-connector-sdk/*"
find . -name "ConnectorCapabilities.java" -path "*/supaflow-core/*"
find . -name "Property.java" -path "*/supaflow-connector-sdk/*"
find . -name "PropertyType.java" -path "*/supaflow-connector-sdk/*"
```

### Confirm Understanding

Before proceeding, you should be able to answer:

1. What does `getType()` return and how is it formatted? (SCREAMING_SNAKE_CASE)
2. What is the difference between `getType()` and `getName()`?
3. What PropertyTypes are available for connection properties?
4. How do you mark a property as required? As encrypted? As hidden?
5. What is `relatedPropertyNameAndValue` used for?
6. What capabilities does ConnectorCapabilities define?

---

## Step 1: Implement getType()

The connector type is a unique identifier in SCREAMING_SNAKE_CASE:

```java
@Override
public String getType() {
    return "SFMC";  // or "HUBSPOT", "AIRTABLE", "ORACLE_TM", etc.
}
```

**Rules**:
- SCREAMING_SNAKE_CASE (uppercase with underscores)
- Must be unique across all connectors
- Used in database records and API calls
- Cannot contain spaces or special characters

---

## Step 2: Implement getName()

The display name shown in the UI:

```java
@Override
public String getName() {
    return "Salesforce Marketing Cloud";  // Human-readable name
}
```

**Rules**:
- Human-readable, properly capitalized
- Can contain spaces
- Shown in connector selection UI

---

## Step 3: Implement getIcon()

Return Base64-encoded SVG icon:

```java
@Override
public String getIcon() {
    try (InputStream is = getClass().getResourceAsStream("/icons/sfmc.svg")) {
        if (is == null) {
            log.warn("Icon not found, using empty string");
            return "";
        }
        byte[] bytes = is.readAllBytes();
        return Base64.getEncoder().encodeToString(bytes);
    } catch (IOException e) {
        log.warn("Failed to load icon", e);
        return "";
    }
}
```

**Alternative - Load from supaflow-www**:

If the icon exists in `supaflow-www/public/connectors/`:

```java
@Override
public String getIcon() {
    // Read from external path during development
    // In production, icon should be in resources/icons/
    Path iconPath = Path.of("/path/to/supaflow-www/public/connectors/salesforce_marketing_cloud.svg");
    try {
        byte[] bytes = Files.readAllBytes(iconPath);
        return Base64.getEncoder().encodeToString(bytes);
    } catch (IOException e) {
        log.warn("Failed to load icon from {}", iconPath, e);
        return "";
    }
}
```

**Best Practice**: Copy the icon to `src/main/resources/icons/` so it's bundled with the JAR.

---

## Step 4: Implement getCategory()

```java
@Override
public ConnectorCategory getCategory() {
    return ConnectorCategory.MARKETING;  // or CRM, DATABASE, FILE, etc.
}
```

**Available Categories** (check `ConnectorCategory` enum):
- `DATABASE` - PostgreSQL, Snowflake, MySQL
- `CRM` - Salesforce, HubSpot
- `MARKETING` - Marketing platforms
- `FILE` - S3, SFTP, Google Drive
- `OTHER` - Catch-all

---

## Step 5: Define Connection Properties

Properties are defined as class fields with `@Property` annotations:

```java
// ================================================================
// CONNECTION PROPERTIES
// ================================================================

@Property(
    displayOrder = 0,
    label = "Client ID",
    description = "OAuth Client ID from the installed package",
    type = PropertyType.STRING,
    required = true,
    propertyGroup = "Authentication"
)
public String clientId;

@Property(
    displayOrder = 1,
    label = "Client Secret",
    description = "OAuth Client Secret from the installed package",
    type = PropertyType.STRING,
    required = true,
    encrypted = true,      // Stored encrypted in database
    password = true,       // Masked in UI
    sensitive = true,      // Not logged
    propertyGroup = "Authentication"
)
public String clientSecret;

@Property(
    displayOrder = 2,
    label = "Subdomain",
    description = "Your subdomain (e.g., 'mc123abc' from mc123abc.auth.marketingcloudapis.com)",
    type = PropertyType.STRING,
    required = true,
    propertyGroup = "Authentication"
)
public String subdomain;
```

### Property Annotation Attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| `displayOrder` | int | Order in UI (0, 1, 2...) |
| `label` | String | Field label in UI |
| `description` | String | Help text / tooltip |
| `type` | PropertyType | STRING, BOOLEAN, ENUM, INTEGER, OAUTH_CONFIG |
| `required` | boolean | Is this field required? |
| `encrypted` | boolean | Store encrypted in database |
| `password` | boolean | Mask input in UI |
| `sensitive` | boolean | Don't log this value |
| `hidden` | boolean | Don't show in UI |
| `defaultValue` | String | Default value |
| `propertyGroup` | String | Group fields in UI |
| `enumValues` | String[] | For PropertyType.ENUM |
| `relatedPropertyNameAndValue` | String[] | Conditional visibility |

### Conditional Properties with relatedPropertyNameAndValue

Show a property only when another property has a specific value:

```java
@Property(
    displayOrder = 0,
    label = "Authentication Method",
    type = PropertyType.ENUM,
    enumValues = {"oauth", "api_key"},
    required = true,
    propertyGroup = "Authentication"
)
public String authMethod = "oauth";

// Only shown when authMethod = "api_key"
@Property(
    displayOrder = 1,
    label = "API Key",
    type = PropertyType.STRING,
    required = false,  // Not globally required
    encrypted = true,
    password = true,
    sensitive = true,
    propertyGroup = "Authentication",
    relatedPropertyNameAndValue = {"authMethod", "api_key"}  // Conditional
)
public String apiKey;

// Only shown when authMethod = "oauth"
@Property(
    displayOrder = 2,
    label = "OAuth Configuration",
    type = PropertyType.OAUTH_CONFIG,
    required = false,
    hidden = true,  // Config is read by frontend, not shown as field
    propertyGroup = "Authentication",
    relatedPropertyNameAndValue = {"authMethod", "oauth"}
)
public String oauthConfig = getOAuthConfig().toString();
```

### OAuth Configuration (for OAuth2 connectors)

```java
/**
 * OAuth2 Configuration for Authorization Code flow.
 * The frontend reads this to initiate OAuth.
 */
public static OAuthConfig getMyConnectorOAuthConfig() {
    return new OAuthConfig.Builder()
        .withFlowType(OAuthConfig.OAuthFlowType.AUTHORIZATION_CODE)
        .withAuthorizationUrl("https://provider.com/oauth/authorize")
        .withTokenUrl("https://provider.com/oauth/token")
        .withRefreshUrl("https://provider.com/oauth/token")
        .withPKCE(true)  // If provider requires PKCE
        .withScopes("read", "write")
        .withAccessTokenExpiry(3600)
        .withClockSkew(300)
        .build();
}

// Hidden properties populated by OAuth flow
@Property(
    displayOrder = 100,
    label = "Access Token",
    type = PropertyType.STRING,
    hidden = true,
    encrypted = true,
    sensitive = true,
    propertyGroup = "Internal"
)
public String accessToken;

@Property(
    displayOrder = 101,
    label = "Refresh Token",
    type = PropertyType.STRING,
    hidden = true,
    encrypted = true,
    sensitive = true,
    propertyGroup = "Internal"
)
public String refreshToken;

@Property(
    displayOrder = 102,
    label = "Token Expiry",
    type = PropertyType.STRING,
    hidden = true,
    propertyGroup = "Internal"
)
public String tokenExpiresAt;
```

---

## Step 6: Implement getConnectorCapabilities()

Define the high-level capabilities your connector supports using the ConnectorCapabilities enum:

```java
@Override
public Set<ConnectorCapabilities> getConnectorCapabilities() {
    // Source connector example
    return EnumSet.of(ConnectorCapabilities.REPLICATION_SOURCE);

    // Destination connector example
    // return EnumSet.of(ConnectorCapabilities.REPLICATION_DESTINATION);

    // Dual-purpose connector example (both source and destination)
    // return EnumSet.of(
    //     ConnectorCapabilities.REPLICATION_SOURCE,
    //     ConnectorCapabilities.REPLICATION_DESTINATION
    // );
}
```

**Available ConnectorCapabilities:**
- `REPLICATION_SOURCE` - Connector can READ data (implement read(), schema())
- `REPLICATION_DESTINATION` - Connector can WRITE data (implement stage(), load())
- `REVERSE_ETL_DESTINATION` - Connector supports reverse ETL operations

---

## Step 7: Implement getCapabilitiesConfig() (Optional but Recommended)

Define detailed capabilities for the UI using ConnectorCapabilitiesConfigBuilder.

**For Source Connectors:**
```java
@Override
public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
    return ConnectorCapabilitiesConfigBuilder.builder()
        .asAPIConnector()  // Preset for API-based sources
        .build();
}
```

**For Warehouse Destinations:**
```java
@Override
public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
    return ConnectorCapabilitiesConfigBuilder.builder()
        .asCloudWarehouse()  // Preset for warehouse destinations
        .loadModes(LoadMode.APPEND, LoadMode.MERGE)
        .defaultLoadMode(LoadMode.APPEND)
        .destinationTableHandlings(
            DestinationTableHandling.FAIL,
            DestinationTableHandling.REPLACE_SCHEMA,
            DestinationTableHandling.APPEND_SCHEMA
        )
        .defaultDestinationTableHandling(DestinationTableHandling.FAIL)
        .supportsStaging(true)
        .requiresStaging(true)
        .requiresExplicitLoadStep(true)  // If load() is a separate step after stage()
        .canAutoCreateSchema(true)
        .supportsHardDeletes(true)
        .build();
}
```

**For File Storage Destinations (S3, GCS, etc.):**
```java
@Override
public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
    return ConnectorCapabilitiesConfigBuilder.builder()
        .asCloudWarehouse()
        .loadModes(LoadMode.APPEND)
        .defaultLoadMode(LoadMode.APPEND)
        .destinationTableHandlings(DestinationTableHandling.FAIL)
        .defaultDestinationTableHandling(DestinationTableHandling.FAIL)
        .supportsStaging(true)
        .requiresStaging(true)
        .requiresExplicitLoadStep(false)  // stage() writes final files
        .canAutoCreateSchema(false)  // File storage has no schema concept
        .build();
}
```

**Convenience Presets:**
- `.asAPIConnector()` - For API-based sources (REST APIs, SaaS connectors)
- `.asCloudWarehouse()` - For data warehouse destinations (Snowflake, BigQuery)
- `.asDatabase()` - For database destinations (PostgreSQL, MySQL)

**CRITICAL**: Only declare capabilities you actually implement!

| Capability | Only declare if... |
|------------|-------------------|
| `REPLICATION_SOURCE` | You implement read() and schema() methods |
| `REPLICATION_DESTINATION` | You implement stage() and load() methods |
| `LoadMode.MERGE` | You implement MERGE/UPSERT logic in load() |
| `LoadMode.APPEND` | You implement INSERT logic (all connectors should support) |
| `canAutoCreateSchema` | You can create destination schemas/tables automatically |
| `supportsHardDeletes` | You handle deleted records (_supa_deleted flag) |

---

## Step 8: Update Connector Class

Replace the Phase 1 shell methods with real implementations:

```java
package io.supaflow.connectors.sfmc;

import io.supaflow.connector.sdk.SupaflowConnector;
import io.supaflow.connector.sdk.annotation.Property;
import io.supaflow.connector.sdk.metadata.PropertyType;
import io.supaflow.connector.sdk.util.ConnectorCapabilitiesConfigBuilder;
import io.supaflow.core.enums.ConnectorCapabilities;
import io.supaflow.core.enums.ReleaseStage;
import io.supaflow.core.exception.ConnectorException;
import io.supaflow.core.model.connector.ConnectorCapabilitiesConfig;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.InputStream;
import java.util.*;

public class SfmcConnector implements SupaflowConnector {

    private static final Logger log = LoggerFactory.getLogger(SfmcConnector.class);

    // ================================================================
    // CONNECTION PROPERTIES
    // ================================================================

    @Property(displayOrder = 0, label = "Client ID",
              description = "OAuth Client ID from SFMC Installed Package",
              type = PropertyType.STRING, required = true,
              propertyGroup = "Authentication")
    public String clientId;

    @Property(displayOrder = 1, label = "Client Secret",
              description = "OAuth Client Secret from SFMC Installed Package",
              type = PropertyType.STRING, required = true,
              encrypted = true, password = true, sensitive = true,
              propertyGroup = "Authentication")
    public String clientSecret;

    @Property(displayOrder = 2, label = "Subdomain",
              description = "Your SFMC subdomain",
              type = PropertyType.STRING, required = true,
              propertyGroup = "Authentication")
    public String subdomain;

    @Property(displayOrder = 3, label = "Account ID (MID)",
              description = "Marketing Cloud Account ID",
              type = PropertyType.STRING, required = true,
              propertyGroup = "Authentication")
    public String accountId;

    @Property(displayOrder = 10, label = "Historical Sync Start Date",
              description = "Sync from this date (YYYY-MM-DD). Empty = all data.",
              type = PropertyType.STRING, required = false,
              propertyGroup = "Sync Configuration")
    public String historicalSyncStartDate;

    // Hidden internal properties
    @Property(displayOrder = 100, label = "Access Token",
              type = PropertyType.STRING, hidden = true,
              encrypted = true, sensitive = true,
              propertyGroup = "Internal")
    public String accessToken;

    @Property(displayOrder = 101, label = "Token Expiry",
              type = PropertyType.STRING, hidden = true,
              propertyGroup = "Internal")
    public String tokenExpiresAt;

    // ================================================================
    // IDENTITY METHODS (Phase 2 - Implemented)
    // ================================================================

    @Override
    public String getType() {
        return "SFMC";
    }

    @Override
    public String getName() {
        return "Salesforce Marketing Cloud";
    }

    @Override
    public String getDescription() {
        return "Salesforce Marketing Cloud connector for syncing contacts, data extensions, and marketing data";
    }

    @Override
    public String getIcon() {
        try (InputStream is = getClass().getResourceAsStream("/icons/sfmc.svg")) {
            if (is == null) {
                return null;
            }
            return Base64.getEncoder().encodeToString(is.readAllBytes());
        } catch (IOException e) {
            log.warn("Failed to load icon", e);
            return null;
        }
    }

    @Override
    public Set<ConnectorCapabilities> getConnectorCapabilities() {
        // SFMC is a source connector only
        return EnumSet.of(ConnectorCapabilities.REPLICATION_SOURCE);
    }

    @Override
    public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
        return ConnectorCapabilitiesConfigBuilder.builder()
            .asAPIConnector()  // Use API connector preset
            .build();
    }

    @Override
    public String getVersion() throws ConnectorException {
        try (InputStream is = getClass().getClassLoader().getResourceAsStream("version.properties")) {
            if (is == null) {
                throw new ConnectorException("version.properties not found",
                    ConnectorException.ErrorType.CONFIGURATION_ERROR);
            }
            Properties props = new Properties();
            props.load(is);
            return props.getProperty("connector.version", "unknown");
        } catch (IOException e) {
            throw new ConnectorException("Failed to load version", e,
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
        }
    }

    @Override
    public String getVendor() throws ConnectorException {
        try (InputStream is = getClass().getClassLoader().getResourceAsStream("version.properties")) {
            if (is == null) {
                throw new ConnectorException("version.properties not found",
                    ConnectorException.ErrorType.CONFIGURATION_ERROR);
            }
            Properties props = new Properties();
            props.load(is);
            return props.getProperty("connector.vendor", "Supaflow");
        } catch (IOException e) {
            throw new ConnectorException("Failed to load vendor", e,
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
        }
    }

    @Override
    public String getGroupId() throws ConnectorException {
        try (InputStream is = getClass().getClassLoader().getResourceAsStream("version.properties")) {
            if (is == null) {
                throw new ConnectorException("version.properties not found",
                    ConnectorException.ErrorType.CONFIGURATION_ERROR);
            }
            Properties props = new Properties();
            props.load(is);
            return props.getProperty("connector.groupid", "io.supaflow");
        } catch (IOException e) {
            throw new ConnectorException("Failed to load groupId", e,
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
        }
    }

    @Override
    public String getArtifactId() throws ConnectorException {
        try (InputStream is = getClass().getClassLoader().getResourceAsStream("version.properties")) {
            if (is == null) {
                throw new ConnectorException("version.properties not found",
                    ConnectorException.ErrorType.CONFIGURATION_ERROR);
            }
            Properties props = new Properties();
            props.load(is);
            return props.getProperty("connector.artifactid", "supaflow-connector-sfmc");
        } catch (IOException e) {
            throw new ConnectorException("Failed to load artifactId", e,
                ConnectorException.ErrorType.CONFIGURATION_ERROR);
        }
    }

    @Override
    public ReleaseStage getReleaseStage() {
        return ReleaseStage.BRONZE;
    }

    @Override
    public boolean isIdentifierCaseSensitive() {
        // SFMC uses case-insensitive identifiers
        return false;
    }

    @Override
    public Boolean supportsCatalog() {
        return false;
    }

    @Override
    public Boolean supportsMultiCatalog() {
        return false;
    }

    @Override
    public Boolean supportsSchema() {
        return false;
    }

    @Override
    public Boolean supportsPackage() {
        return false;
    }

    @Override
    public String getDefaultCatalog() {
        return null;
    }

    @Override
    public String getDefaultSchema() {
        return null;
    }

    // ================================================================
    // PHASE 3: Connection (Not yet implemented)
    // ================================================================

    @Override
    public void setRuntimeContext(ConnectorRuntimeContext context) {
        // Will be implemented in Phase 3
    }

    @Override
    public DatasourceInitResponse init(Map<String, Object> connectionProperties)
            throws ConnectorException {
        throw new UnsupportedOperationException("Phase 3: Not yet implemented");
    }

    // ... remaining Phase 4, 5 methods still throw UnsupportedOperationException
}
```

---

## Step 9: Register Connector in Parent POM (CRITICAL)

**CRITICAL**: The connector must be registered in the parent reactor for platform builds to include it.

Without this registration:
- ❌ `mvn clean install` from platform root will skip this connector
- ❌ Agent deployments won't include this connector
- ❌ Production builds will be missing this connector

### Edit Parent POM

**File**: `<platform-root>/pom.xml`

**Add in `<modules>` section** (around line 27-33):

```xml
<modules>
    ...
    <module>connectors/supaflow-connector-sdk</module>
    <module>connectors/supaflow-connector-jdbc-common</module>
    <module>connectors/supaflow-connector-postgres</module>
    <module>connectors/supaflow-connector-snowflake</module>
    <module>connectors/supaflow-connector-{name}</module>  <!-- ADD YOUR CONNECTOR -->
    <module>connectors/supaflow-connector-salesforce</module>
    ...
</modules>
```

**Placement Guidelines:**
- Group logically by type (databases → warehouses → CRMs → marketing)
- Or maintain alphabetical order within type groups
- Example ordering: postgres → snowflake → s3 → salesforce (databases → warehouses → CRMs)

### Verify Registration

```bash
# Build from platform root with dependencies
cd <platform-root>
mvn clean compile -pl connectors/supaflow-connector-{name} -am

# You should see in reactor summary:
# [INFO] supaflow-connector-{name} .................... SUCCESS [  X.XXX s]
# [INFO] BUILD SUCCESS
```

**Common Mistake:**

Building directly in connector directory works even without parent POM registration:

```bash
# ⚠️  This succeeds even if NOT registered in parent POM
cd connectors/supaflow-connector-{name}
mvn clean install
```

This is why the issue goes undetected until deployment! Always verify with `-pl` flag from platform root.

---

## Step 10: Dependency Version Management

### Rule: Use Parent POM Versions When Available

The parent POM defines versions for common dependencies in `<dependencyManagement>`.

**Always check parent POM first** before adding version to connector POM:

```bash
# Search parent POM for dependency
grep -A3 "artifactId>commons-codec" ../../pom.xml

# If found, DO NOT specify version in connector POM
```

### Dependencies Managed by Parent POM

**Common utilities** (NEVER specify version in connector POM):

```xml
<!-- ✅ CORRECT: No version, uses parent -->
<dependency>
    <groupId>commons-codec</groupId>
    <artifactId>commons-codec</artifactId>
    <!-- Version managed by parent POM: 1.16.0 -->
</dependency>

<dependency>
    <groupId>com.opencsv</groupId>
    <artifactId>opencsv</artifactId>
    <!-- Version managed by parent POM: 5.11.2 -->
</dependency>

<dependency>
    <groupId>commons-io</groupId>
    <artifactId>commons-io</artifactId>
    <!-- Version managed by parent POM: 2.14.0 -->
</dependency>

<!-- ❌ WRONG: Hardcoded version when parent defines it -->
<dependency>
    <groupId>commons-codec</groupId>
    <artifactId>commons-codec</artifactId>
    <version>1.15</version>  <!-- Version conflict! Parent has 1.16.0 -->
</dependency>
```

**Internal modules** (NEVER specify version):

```xml
<dependency>
    <groupId>io.supaflow</groupId>
    <artifactId>supaflow-connector-sdk</artifactId>
    <!-- Version inherited from parent: ${project.version} -->
</dependency>

<dependency>
    <groupId>io.supaflow</groupId>
    <artifactId>supaflow-connector-jdbc-common</artifactId>
    <!-- Version inherited from parent: ${project.version} -->
</dependency>
```

**Test framework** (managed by Spring Boot BOM or parent):

```xml
<dependency>
    <groupId>org.junit.jupiter</groupId>
    <artifactId>junit-jupiter</artifactId>
    <scope>test</scope>
    <!-- Version from Spring Boot BOM: 5.10.x -->
</dependency>

<dependency>
    <groupId>org.mockito</groupId>
    <artifactId>mockito-junit-jupiter</artifactId>
    <scope>test</scope>
    <!-- Version managed by parent: 5.2.0 -->
</dependency>

<dependency>
    <groupId>org.mockito</groupId>
    <artifactId>mockito-core</artifactId>
    <scope>test</scope>
    <!-- Version managed by parent: 5.15.2 -->
</dependency>
```

**Exception: Test logging** (OK to specify version for consistency):

```xml
<dependency>
    <groupId>ch.qos.logback</groupId>
    <artifactId>logback-classic</artifactId>
    <version>1.5.13</version>  <!-- ✅ OK: Test scope, consistent across connectors -->
    <scope>test</scope>
</dependency>
```

### Connector-Specific Dependencies

**When to define version in connector POM:**
- Connector-specific libraries (e.g., AWS SDK, Snowflake JDBC, Salesforce API)
- Not used by other connectors
- Requires specific version compatibility

**Best practice: Use properties for version management**

```xml
<properties>
    <libs.output.dir>${project.basedir}/../../../supaflow-connector-libs</libs.output.dir>
    <groupId.path>io/supaflow</groupId.path>

    <!-- Connector-specific dependency versions -->
    <aws.sdk.version>2.20.0</aws.sdk.version>
    <parquet.version>1.13.1</parquet.version>
    <hadoop.version>3.3.6</hadoop.version>
</properties>

<dependencies>
    <!-- ✅ CORRECT: Connector-specific dependency -->
    <dependency>
        <groupId>software.amazon.awssdk</groupId>
        <artifactId>s3</artifactId>
        <version>${aws.sdk.version}</version>
    </dependency>
</dependencies>
```

### Quick Reference: Parent POM Managed Dependencies

| Dependency | Parent Version | Rule |
|------------|---------------|------|
| commons-codec | 1.16.0 | Omit version |
| commons-io | 2.14.0 | Omit version |
| opencsv | 5.11.2 | Omit version |
| slf4j-api | 2.0.9 | Omit version |
| jackson-* | 2.18.2 | Omit version |
| mockito-core | 5.15.2 | Omit version |
| mockito-junit-jupiter | 5.2.0 | Omit version |
| junit-jupiter | Spring Boot BOM | Omit version |
| supaflow-* | ${project.version} | Omit version |
| logback-classic (test) | 1.5.13 | OK to specify |

### Verify Dependency Versions

```bash
# Check for version conflicts
mvn dependency:tree -pl connectors/supaflow-connector-{name}

# Look for warnings like:
# [WARNING] ... version conflict between ... and ...
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
| CHECK 5 | ✓ Connector capabilities defined |
| CHECK 6 | ✓ Property annotations found |
| CHECK 9 | ✓ pom.xml and shade plugin |
| CHECK 11 | ✓ getType/getName conventions |
| CHECK 14 | ✓ No target/ in git |

### Manual Checklist

Before proceeding to Phase 3, confirm ALL of the following:

| Check | Verification |
|-------|--------------|
| ☐ getType() returns SCREAMING_SNAKE_CASE | Code review |
| ☐ getName() returns human-readable name | Code review |
| ☐ getIcon() loads icon or returns empty string | Compile succeeds |
| ☐ getCategory() returns valid category | Code review |
| ☐ All required properties have `required = true` | Code review |
| ☐ Sensitive properties have `encrypted`, `password`, `sensitive` | Code review |
| ☐ Properties have proper `displayOrder` | Code review |
| ☐ Properties grouped logically with `propertyGroup` | Code review |
| ☐ Capabilities match what you WILL implement | Review against plan |
| ☐ Connector registered in parent pom.xml | `grep "supaflow-connector-{name}" ../../pom.xml` |
| ☐ Reactor build includes connector | `mvn compile -pl connectors/supaflow-connector-{name} -am` |
| ☐ No hardcoded versions for parent-managed deps | Review dependencies section |
| ☐ CHECK 5, 6, 11, 25, 26 pass | Verification script |

### Show Your Work

Before proceeding to Phase 3, show:

1. Output of `mvn compile`
2. Output of `bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>` (CHECKs 5, 6, 11)
3. List of properties defined with their types
4. Capabilities declared

---

## Common Mistakes to Avoid

| Mistake | Why It's Wrong | Correct Approach |
|---------|----------------|------------------|
| Not registering in parent pom.xml | Connector skipped in platform builds | Add `<module>` entry in parent pom.xml |
| Hardcoding dependency versions | Version conflicts, missed updates | Omit version for parent-managed deps |
| Building only in connector directory | Misses parent POM issues | Verify with `mvn compile -pl ... -am` from root |
| getType() not SCREAMING_SNAKE_CASE | Convention violation | Use "SFMC" not "sfmc" or "Sfmc" |
| Declaring capabilities you don't implement | Executor expects them to work | Only declare what you'll build |
| Missing `encrypted` on secrets | Credentials stored in plaintext | Always encrypt sensitive data |
| Properties without `displayOrder` | Random order in UI | Number them 0, 1, 2... |
| Skipping icon implementation | Missing icon in UI | Load from resources or return "" |
| Using PropertyType.STRING for booleans | Wrong UI widget rendered | Use PropertyType.BOOLEAN |

---

## Next Phase

Once all gate checks pass, proceed to:
→ **PHASE_3_CONNECTION_AUTH.md**
