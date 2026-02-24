#!/bin/bash
# verify_connector.sh - Comprehensive connector implementation verification
# Usage: ./verify_connector.sh <connector-name> [platform-root]
#
# Example: ./verify_connector.sh oracle-tm /path/to/supaflow-platform

if [ -z "$1" ]; then
    echo "Usage: $0 <connector-name> [platform-root]"
    echo "Example: $0 oracle-tm /path/to/supaflow-platform"
    exit 1
fi

CONNECTOR_NAME="$1"
PLATFORM_ROOT="${2:-${SUPAFLOW_PLATFORM_ROOT:-$(pwd)}}"

if [ ! -d "$PLATFORM_ROOT" ]; then
    echo "ERROR: Platform root does not exist: $PLATFORM_ROOT"
    exit 1
fi

if [ ! -f "$PLATFORM_ROOT/pom.xml" ] || [ ! -d "$PLATFORM_ROOT/connectors" ]; then
    echo "ERROR: Platform root must contain pom.xml and connectors/: $PLATFORM_ROOT"
    exit 1
fi

cd "$PLATFORM_ROOT" || exit 1

CONNECTOR_DIR="connectors/supaflow-connector-${CONNECTOR_NAME}"
CONNECTOR_SRC_DIR="$CONNECTOR_DIR/src/main/java/io/supaflow/connector"

# Find the main connector Java file
CONNECTOR_FILE=$(find "$CONNECTOR_SRC_DIR" -name "*Connector.java" -not -name "*IT.java" | head -1)

if [ ! -f "$CONNECTOR_FILE" ]; then
    echo "❌ ERROR: Connector file not found in $CONNECTOR_SRC_DIR"
    exit 1
fi

# Get the directory containing the main connector file (for helper class checks)
CONNECTOR_CLASS_DIR=$(dirname "$CONNECTOR_FILE")

echo "==================================================================="
echo "  Supaflow Connector Implementation Verification"
echo "==================================================================="
echo "Connector: $CONNECTOR_NAME"
echo "File: $CONNECTOR_FILE"
echo ""

ERRORS=0
WARNINGS=0

# Detect connector type (JDBC vs REST)
IS_JDBC_CONNECTOR=false
if grep -q "extends BaseJdbcConnector" "$CONNECTOR_FILE"; then
    IS_JDBC_CONNECTOR=true
    echo "ℹ️  Detected: JDBC Connector (extends BaseJdbcConnector)"
    echo "   → Many methods inherited from base class"
    echo ""
fi

# Detect connector capabilities (SOURCE / DESTINATION / DUAL-PURPOSE)
IS_SOURCE_CONNECTOR=false
IS_DESTINATION_CONNECTOR_EARLY=false

if grep -q "REPLICATION_SOURCE" "$CONNECTOR_FILE"; then
    IS_SOURCE_CONNECTOR=true
fi

if grep -q "REPLICATION_DESTINATION\|REVERSE_ETL_DESTINATION" "$CONNECTOR_FILE"; then
    IS_DESTINATION_CONNECTOR_EARLY=true
fi

# Display connector purpose
if $IS_SOURCE_CONNECTOR && $IS_DESTINATION_CONNECTOR_EARLY; then
    echo "ℹ️  Detected: DUAL-PURPOSE Connector (source + destination)"
    echo "   → Will run both source and destination checks"
    echo ""
elif $IS_SOURCE_CONNECTOR; then
    echo "ℹ️  Detected: SOURCE-ONLY Connector"
    echo "   → Will skip destination checks (16-24)"
    echo ""
elif $IS_DESTINATION_CONNECTOR_EARLY; then
    echo "ℹ️  Detected: DESTINATION-ONLY Connector"
    echo "   → Will skip source checks (1-2, 8, 12-13)"
    echo ""
fi

# ==============================================================================
# SOURCE CONNECTOR CHECKS (1-15)
# Skip for destination-only connectors unless they also have source capability
# ==============================================================================
if ! $IS_SOURCE_CONNECTOR && $IS_DESTINATION_CONNECTOR_EARLY; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⏭  SKIPPING SOURCE CHECKS (1-15)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "ℹ️  Connector is destination-only - source checks not applicable"
    echo ""
    # Skip to destination checks section
    SKIP_SOURCE_CHECKS=true
else
    SKIP_SOURCE_CHECKS=false
fi

# ==============================================================================
# Find IT test file (used by both source and destination checks)
# ==============================================================================
IT_TEST_FILE=$(find "$CONNECTOR_DIR/src/test" -name "*ConnectorIT.java" 2>/dev/null | head -1)

if ! $SKIP_SOURCE_CHECKS; then
# ==============================================================================
# CRITICAL CHECK 1: RecordProcessor Lifecycle
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 1: RecordProcessor Lifecycle (CRITICAL)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if $IS_JDBC_CONNECTOR; then
    echo "ℹ️  JDBC connector - BaseJdbcConnector handles RecordProcessor lifecycle"
    echo "✓ getRecordProcessor() handled by base class"
    echo "✓ processRecord() handled by base class"
    echo "✓ completeProcessing()/getResult() handled by base class"
    echo "✓ SyncStateResponseBuilder handled by base class"
else
    if ! grep -q "\.getRecordProcessor()" "$CONNECTOR_FILE"; then
        echo "❌ CRITICAL: Missing .getRecordProcessor() call"
        echo "   → Must obtain processor from request: request.getRecordProcessor()"
        ERRORS=$((ERRORS + 1))
    else
        echo "✓ Found .getRecordProcessor() call"
    fi

    if ! grep -q "\.processRecord(" "$CONNECTOR_FILE"; then
        # Check if processRecord exists in helper classes (Reader, Writer, Parser)
        HELPER_PROCESS=$(grep -rl "\.processRecord(" "$CONNECTOR_CLASS_DIR"/ --include="*.java" 2>/dev/null | head -1 || true)
        if [[ -n "$HELPER_PROCESS" ]]; then
            echo "✓ Found .processRecord() in helper class"
            echo "   → $(basename "$HELPER_PROCESS")"
        else
            echo "❌ CRITICAL: Missing .processRecord() call"
            echo "   → Must call processor.processRecord(record, fields) for each record"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "✓ Found .processRecord() call"
    fi

    # Check for either completeProcessing() or getResult() - both are valid
    # completeProcessing() internally calls getResult(), so they're functionally identical
    if grep -q "\.completeProcessing()\|processor\.getResult()\|\.getResult()" "$CONNECTOR_FILE"; then
        if grep -q "\.completeProcessing()" "$CONNECTOR_FILE"; then
            echo "✓ Found .completeProcessing() call"
        else
            echo "✓ Found .getResult() call (equivalent to completeProcessing)"
        fi
    else
        echo "❌ CRITICAL: Missing .completeProcessing() or .getResult() call"
        echo "   → Must call processor.completeProcessing() or processor.getResult()"
        echo "   → This returns RecordProcessingResult for building response"
        ERRORS=$((ERRORS + 1))
    fi

    if ! grep -q "SyncStateResponseBuilder" "$CONNECTOR_FILE"; then
        echo "❌ CRITICAL: Missing SyncStateResponseBuilder usage"
        echo "   → Must use SyncStateResponseBuilder.fromProcessingResult()"
        ERRORS=$((ERRORS + 1))
    else
        # Check for fromProcessingResult - may be on same line or next line
        if ! grep -q "fromProcessingResult" "$CONNECTOR_FILE"; then
            echo "⚠️  WARNING: SyncStateResponseBuilder found but not fromProcessingResult()"
            echo "   → Should use: SyncStateResponseBuilder.fromProcessingResult(result, mode)"
            WARNINGS=$((WARNINGS + 1))
        else
            echo "✓ Found SyncStateResponseBuilder.fromProcessingResult()"
        fi
    fi
fi

# NOTE: Connectors should NOT call processor.close()
# The pipeline (creator) manages processor lifecycle via try-with-resources
# Principle: "whoever creates it, closes it"
# Only flag actual code calls, not comments (grep -v filters out comment lines)
if grep -v '^\s*//' "$CONNECTOR_FILE" | grep -v '^\s*\*' | grep -q "processor\.close()"; then
    echo "⚠️  WARNING: Connector calls processor.close()"
    echo "   → Connectors should NOT close the processor"
    echo "   → The pipeline manages processor lifecycle via try-with-resources"
    echo "   → Principle: creator is responsible for cleanup, not the child"
    WARNINGS=$((WARNINGS + 1))
else
    echo "✓ Correctly does NOT close processor (pipeline manages lifecycle)"
fi

echo ""

# ==============================================================================
# CRITICAL CHECK 2: DatasourceInitResponse
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 2: DatasourceInitResponse Usage"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if $IS_JDBC_CONNECTOR; then
    echo "ℹ️  JDBC connector - BaseJdbcConnector handles DatasourceInitResponse"
    echo "✓ setDatasourceProductName() handled by base class"
    echo "✓ setDatasourceProductVersion() handled by base class"
else
    if grep -q "\.setStatus(" "$CONNECTOR_FILE"; then
        echo "❌ ERROR: Using .setStatus() on DatasourceInitResponse"
        echo "   → WRONG: response.setStatus()"
        echo "   → CORRECT: response.setDatasourceProductName()"
        ERRORS=$((ERRORS + 1))
    fi

    if grep -q "\.setMessage(" "$CONNECTOR_FILE"; then
        echo "❌ ERROR: Using .setMessage() on DatasourceInitResponse"
        echo "   → WRONG: response.setMessage()"
        echo "   → CORRECT: response.setDatasourceProductVersion()"
        ERRORS=$((ERRORS + 1))
    fi

    if ! grep -q "setDatasourceProductName" "$CONNECTOR_FILE"; then
        echo "⚠️  WARNING: Missing setDatasourceProductName() call"
        echo "   → Should set product name in init() response"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "✓ Found setDatasourceProductName()"
    fi

    if ! grep -q "setDatasourceProductVersion" "$CONNECTOR_FILE"; then
        echo "⚠️  WARNING: Missing setDatasourceProductVersion() call"
        echo "   → Should set product version in init() response"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "✓ Found setDatasourceProductVersion()"
    fi
fi

echo ""

# ==============================================================================
# CHECK 3: Required Methods
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 3: Required Methods Implementation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if $IS_JDBC_CONNECTOR; then
    echo "ℹ️  JDBC connector - BaseJdbcConnector provides core methods"
    echo "✓ init(), schema(), read(), close() inherited from base class"
    echo "✓ setRuntimeContext() inherited from base class"

    # Only check for connector-specific overrides
    if grep -q "getVersion" "$CONNECTOR_FILE"; then
        echo "✓ Found getVersion()"
    else
        echo "⚠️  WARNING: Missing getVersion() - should return connector version"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -q "getCapabilitiesConfig" "$CONNECTOR_FILE"; then
        echo "✓ Found getCapabilitiesConfig()"
    else
        echo "⚠️  WARNING: Missing getCapabilitiesConfig() - may be inherited"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    REQUIRED_METHODS=(
        "setRuntimeContext"
        "getVersion"
        "getCapabilitiesConfig"
        "public.*init"
        "public.*schema"
        "public.*read"
        "public.*close"
    )

    for method in "${REQUIRED_METHODS[@]}"; do
        if ! grep -q "$method" "$CONNECTOR_FILE"; then
            echo "❌ MISSING: $method() method"
            ERRORS=$((ERRORS + 1))
        else
            echo "✓ Found $method()"
        fi
    done
fi

echo ""

# ==============================================================================
# CHECK 3.5: FieldMetadata Requirements (for REST connectors)
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 3.5: FieldMetadata Requirements"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if this is a JDBC connector (extends BaseJdbcConnector)
if grep -q "extends BaseJdbcConnector" "$CONNECTOR_FILE"; then
    echo "ℹ️  JDBC connector - BaseJdbcConnector handles FieldMetadata automatically"
    echo "✓ setOriginalDataType() handled by base class"
else
    # REST connector - must set originalDataType manually
    if grep -q "new FieldMetadata()" "$CONNECTOR_FILE"; then
        echo "ℹ️  REST connector creates FieldMetadata objects"

        if grep -q "setOriginalDataType" "$CONNECTOR_FILE"; then
            echo "✓ Found setOriginalDataType() calls"
        else
            echo "❌ ERROR: Missing setOriginalDataType() in schema discovery"
            echo "   → FieldMetadata MUST have originalDataType set"
            echo "   → This is the source system's type (e.g., 'string', 'datetime')"
            echo "   → Used by CSV processor, schema evolution, and destination DDL"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -q "setCanonicalType" "$CONNECTOR_FILE"; then
            echo "✓ Found setCanonicalType() calls"
        else
            echo "❌ ERROR: Missing setCanonicalType() in schema discovery"
            echo "   → FieldMetadata MUST have canonicalType set"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "ℹ️  No direct FieldMetadata creation found"
    fi
fi

echo ""

# ==============================================================================
# CHECK 4: Version Management
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 4: Version Management"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f "$CONNECTOR_DIR/src/main/resources/version.properties" ]; then
    echo "❌ CRITICAL: Missing version.properties file"
    echo "   → Create: $CONNECTOR_DIR/src/main/resources/version.properties"
    echo "   → Content: connector.version=\${project.version}"
    ERRORS=$((ERRORS + 1))
else
    echo "✓ Found version.properties"
    if ! grep -q "connector.version=" "$CONNECTOR_DIR/src/main/resources/version.properties"; then
        echo "⚠️  WARNING: version.properties missing 'connector.version=' entry"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

echo ""

# ==============================================================================
# CHECK 5: Capabilities
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 5: Connector Capabilities"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if grep -q "ConnectorCapabilities\.READ\b" "$CONNECTOR_FILE"; then
    echo "❌ ERROR: Using ConnectorCapabilities.READ"
    echo "   → WRONG: ConnectorCapabilities.READ (doesn't exist)"
    echo "   → CORRECT: ConnectorCapabilities.REPLICATION_SOURCE"
    ERRORS=$((ERRORS + 1))
fi

if grep -q "ConnectorCapabilities\.WRITE\b" "$CONNECTOR_FILE"; then
    echo "❌ ERROR: Using ConnectorCapabilities.WRITE"
    echo "   → WRONG: ConnectorCapabilities.WRITE (doesn't exist)"
    echo "   → CORRECT: ConnectorCapabilities.REPLICATION_DESTINATION"
    ERRORS=$((ERRORS + 1))
fi

if grep -q "ConnectorCapabilities\.SCHEMA_DISCOVERY" "$CONNECTOR_FILE"; then
    echo "❌ ERROR: Using ConnectorCapabilities.SCHEMA_DISCOVERY"
    echo "   → This capability doesn't exist, remove it"
    ERRORS=$((ERRORS + 1))
fi

if grep -q "REPLICATION_SOURCE\|REPLICATION_DESTINATION" "$CONNECTOR_FILE"; then
    echo "✓ Using correct capability enums"
fi

echo ""

# ==============================================================================
# CHECK 6: Property Annotations
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 6: Property Annotations"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if grep -q "@Property" "$CONNECTOR_FILE"; then
    echo "✓ Found @Property annotations"

    # Check for invalid labels (SDK validates via ConnectionPropertyUtil.containsSpecialCharacters)
    # Pattern [^a-z0-9 ] means ONLY alphanumeric + spaces allowed
    # Check for any special characters in labels
    INVALID_LABELS=$(grep -oE 'label\s*=\s*"[^"]*"' "$CONNECTOR_FILE" | grep -E '"[^"]*[^a-zA-Z0-9 "][^"]*"' || true)
    if [[ -n "$INVALID_LABELS" ]]; then
        echo "❌ ERROR: Property labels contain special characters"
        echo "   → SDK validates labels with: Pattern.compile(\"[^a-z0-9 ]\", CASE_INSENSITIVE)"
        echo "   → Labels can ONLY contain: letters, numbers, spaces"
        echo "   → Invalid labels found:"
        echo "$INVALID_LABELS" | while read -r line; do
            echo "      $line"
        done
        echo "   → Fix: Remove parentheses (), brackets [], hyphens -, underscores _, etc."
        ERRORS=$((ERRORS + 1))
    else
        echo "✓ Property labels are compliant (alphanumeric + spaces only)"
    fi

    # Check for PropertyType.INTEGER
    if grep -q "PropertyType\.INTEGER" "$CONNECTOR_FILE"; then
        echo "❌ ERROR: Using PropertyType.INTEGER"
        echo "   → WRONG: PropertyType.INTEGER (doesn't exist)"
        echo "   → CORRECT: PropertyType.NUMERIC"
        ERRORS=$((ERRORS + 1))
    fi

else
    echo "⚠️  WARNING: No @Property annotations found"
    echo "   → Connector should have properties for configuration"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# ==============================================================================
# CHECK 7: Connection Pooling / HTTP Client
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 7: Connection Management"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check for JDBC pooling
if grep -q "HikariCP\|HikariConfig\|HikariDataSource" "$CONNECTOR_FILE"; then
    echo "✓ Found HikariCP connection pooling (JDBC)"
fi

# Check for HTTP client
if grep -q "OkHttpClient\|HttpClient" "$CONNECTOR_FILE"; then
    echo "✓ Found HTTP client (REST API)"

    if grep -q "runtimeContext.*getHttpClientConfig\|getHttpClientConfig()" "$CONNECTOR_FILE"; then
        echo "✓ Using runtime context HTTP client config"
    else
        echo "⚠️  WARNING: Not using runtime context HTTP client config"
        echo "   → Consider using runtimeContext.getHttpClientConfig() for:"
        echo "     - Consistent timeout settings"
        echo "     - Enterprise proxy support"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

echo ""

# ==============================================================================
# CHECK 8: Incremental Sync (if applicable)
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 8: Incremental Sync Implementation (if applicable)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if grep -q "identifyCursorFields\|setCursorField\|SyncStateRequest" "$CONNECTOR_FILE"; then
    echo "ℹ️  Incremental sync features detected"

    if grep -q "identifyCursorFields" "$CONNECTOR_FILE"; then
        echo "✓ Found identifyCursorFields() implementation"

        # Check for hardcoded field names
        if grep -q 'setCursorField.*"updated_at"\|setCursorField.*"modified_date"' "$CONNECTOR_FILE"; then
            echo "⚠️  WARNING: Possible hardcoded cursor field name"
            echo "   → Should use priority-based search, not hardcode field names"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    if grep -q "getServerTimeOffset" "$CONNECTOR_FILE"; then
        echo "✓ Found getServerTimeOffset() implementation (cutoff time strategy)"
    fi

    if grep -q "lookback" "$CONNECTOR_FILE"; then
        echo "✓ Found lookback window implementation"
    fi

    if grep -q "SyncStateRequest" "$CONNECTOR_FILE"; then
        echo "✓ Found SyncStateRequest handling"
    fi
else
    echo "ℹ️  No incremental sync features detected (full refresh only)"
fi

echo ""

# ==============================================================================
# CHECK 9: Build Configuration
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 9: Build Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f "$CONNECTOR_DIR/pom.xml" ]; then
    echo "❌ CRITICAL: Missing pom.xml"
    ERRORS=$((ERRORS + 1))
else
    echo "✓ Found pom.xml"

    # Check for maven-shade-plugin (creates uber-jar with dependencies)
    if ! grep -q "maven-shade-plugin" "$CONNECTOR_DIR/pom.xml"; then
        echo "⚠️  WARNING: Missing maven-shade-plugin"
        echo "   → Production connectors need shade plugin to create uber-jar"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "✓ Found maven-shade-plugin (uber-jar packaging)"
    fi
fi

echo ""

# ==============================================================================
# CHECK 10: OAuth Implementation (if applicable)
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 10: OAuth Implementation (if applicable)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if grep -q "OAuthConfig\|oauthConfig\|accessToken\|refreshToken" "$CONNECTOR_FILE"; then
    echo "ℹ️  OAuth features detected"

    if grep -q "OAuthConfig\.Builder" "$CONNECTOR_FILE"; then
        echo "✓ Found OAuthConfig.Builder implementation"

        if grep -q "withScopes" "$CONNECTOR_FILE"; then
            echo "✓ Found scope configuration"
            echo "   ℹ️  Verify all required scopes are included"
        else
            echo "⚠️  WARNING: OAuthConfig found but no scopes configured"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    # Check for token refresh patterns (various implementations)
    if grep -qi "refreshToken\|tokenRefresh\|refresh.*token\|token.*refresh\|expired.*refresh\|refreshing" "$CONNECTOR_FILE"; then
        echo "✓ Found token refresh logic"
    else
        echo "⚠️  WARNING: OAuth tokens found but no refresh logic"
        echo "   → Should handle token expiry and refresh"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -q "isTokenExpired\|tokenExpiresAt" "$CONNECTOR_FILE"; then
        echo "✓ Found token expiry checking"
    fi
else
    echo "ℹ️  No OAuth features detected"
fi

echo ""

# ==============================================================================
# CHECK 11: Naming Conventions (CRITICAL)
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 11: Naming Conventions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Extract getType() return value
CONNECTOR_TYPE=$(grep -A2 'public String getType()' "$CONNECTOR_FILE" | grep 'return' | sed 's/.*return[[:space:]]*"\([^"]*\)".*/\1/' | head -1)

# Also check for constant reference (e.g., return CONNECTOR_ID)
if [[ -z "$CONNECTOR_TYPE" ]] || [[ "$CONNECTOR_TYPE" == *"return"* ]]; then
    CONSTANT_NAME=$(grep -A2 'public String getType()' "$CONNECTOR_FILE" | grep 'return' | sed 's/.*return[[:space:]]*\([A-Z_]*\);.*/\1/' | head -1)
    if [[ -n "$CONSTANT_NAME" ]]; then
        CONNECTOR_TYPE=$(grep "private static final String $CONSTANT_NAME" "$CONNECTOR_FILE" | sed 's/.*=.*"\([^"]*\)".*/\1/')
    fi
fi

if [[ -n "$CONNECTOR_TYPE" ]]; then
    echo "  getType() returns: \"$CONNECTOR_TYPE\""

    # Check for spaces
    if [[ "$CONNECTOR_TYPE" == *" "* ]]; then
        echo "❌ ERROR: getType() contains SPACES"
        echo "   → Type must NOT contain spaces"
        echo "   → Current: \"$CONNECTOR_TYPE\""
        echo "   → Fix: Remove all spaces, use underscores if needed"
        ERRORS=$((ERRORS + 1))
    # Check for lowercase letters
    elif [[ "$CONNECTOR_TYPE" =~ [a-z] ]]; then
        echo "⚠️  WARNING: getType() contains lowercase letters"
        echo "   → Convention: SCREAMING_SNAKE_CASE (all uppercase)"
        echo "   → Current: \"$CONNECTOR_TYPE\""
        WARNINGS=$((WARNINGS + 1))
    # Check for special characters (other than underscore)
    elif [[ "$CONNECTOR_TYPE" =~ [^A-Z0-9_] ]]; then
        echo "❌ ERROR: getType() contains special characters"
        echo "   → Only uppercase letters, numbers, and underscores allowed"
        echo "   → Current: \"$CONNECTOR_TYPE\""
        ERRORS=$((ERRORS + 1))
    else
        echo "✓ getType() naming is compliant (SCREAMING_SNAKE_CASE)"
    fi
else
    echo "⚠️  WARNING: Could not extract getType() return value"
    WARNINGS=$((WARNINGS + 1))
fi

# Extract getName() return value
CONNECTOR_DISPLAY_NAME=$(grep -A2 'public String getName()' "$CONNECTOR_FILE" | grep 'return' | sed 's/.*return[[:space:]]*"\([^"]*\)".*/\1/' | head -1)

# Also check for constant reference
if [[ -z "$CONNECTOR_DISPLAY_NAME" ]] || [[ "$CONNECTOR_DISPLAY_NAME" == *"return"* ]]; then
    CONSTANT_NAME=$(grep -A2 'public String getName()' "$CONNECTOR_FILE" | grep 'return' | sed 's/.*return[[:space:]]*\([A-Z_]*\);.*/\1/' | head -1)
    if [[ -n "$CONSTANT_NAME" ]]; then
        CONNECTOR_DISPLAY_NAME=$(grep "private static final String $CONSTANT_NAME" "$CONNECTOR_FILE" | sed 's/.*=.*"\([^"]*\)".*/\1/')
    fi
fi

if [[ -n "$CONNECTOR_DISPLAY_NAME" ]]; then
    echo "  getName() returns: \"$CONNECTOR_DISPLAY_NAME\""

    # Check for special characters (spaces are allowed in display names)
    if [[ "$CONNECTOR_DISPLAY_NAME" =~ [^A-Za-z0-9\ ] ]]; then
        echo "❌ ERROR: getName() contains special characters"
        echo "   → Only alphanumeric characters and spaces allowed"
        echo "   → Current: \"$CONNECTOR_DISPLAY_NAME\""
        ERRORS=$((ERRORS + 1))
    else
        echo "✓ getName() naming is compliant"
    fi
else
    echo "⚠️  WARNING: Could not extract getName() return value"
    WARNINGS=$((WARNINGS + 1))
fi

# Check property field names (should be camelCase, no underscores in public fields)
PROPERTY_FIELDS=$(grep -B1 '@Property' "$CONNECTOR_FILE" | grep -E 'public\s+(String|Integer|Boolean|int|boolean|Long|long)' | sed 's/.*public[[:space:]]*[A-Za-z]*[[:space:]]*\([a-zA-Z0-9_]*\).*/\1/')
BAD_FIELDS=""
for field in $PROPERTY_FIELDS; do
    if [[ "$field" == *"_"* ]]; then
        BAD_FIELDS="$BAD_FIELDS $field"
    fi
done

if [[ -n "$BAD_FIELDS" ]]; then
    echo "⚠️  WARNING: Property fields use underscores instead of camelCase:"
    echo "   → Fields:$BAD_FIELDS"
    echo "   → Convention: camelCase (e.g., 'sslMode' not 'ssl_mode')"
    WARNINGS=$((WARNINGS + 1))
else
    FIELD_COUNT=$(echo "$PROPERTY_FIELDS" | wc -w | tr -d ' ')
    if [[ "$FIELD_COUNT" -gt 0 ]]; then
        echo "✓ Property fields use camelCase ($FIELD_COUNT fields)"
    fi
fi

# Check icon lookup
echo ""
echo "  Icon Check:"

# Derive expected icon filename from connector name
if [[ -n "$CONNECTOR_DISPLAY_NAME" ]]; then
    # Convert PascalCase to lowercase_with_underscores
    # e.g., OracleTM -> oracle_tm, HubSpot -> hubspot, Postgres -> postgres
    # Insert underscore before each uppercase letter (except first), then lowercase all
    ICON_NAME=$(echo "$CONNECTOR_DISPLAY_NAME" | sed 's/\([A-Z]\)/_\1/g' | sed 's/^_//' | tr '[:upper:]' '[:lower:]')

    # Check in supaflow-www (relative path from supaflow-platform)
    ICON_PATH="../supaflow-www/public/connectors/${ICON_NAME}.svg"
    ICON_FOUND=""

    if [ -f "$ICON_PATH" ]; then
        echo "✓ Found icon: connectors/${ICON_NAME}.svg"
        ICON_FOUND="yes"
    else
        # Try without underscores (e.g., hubspot instead of hub_spot)
        ICON_NAME_SIMPLE=$(echo "$CONNECTOR_DISPLAY_NAME" | tr '[:upper:]' '[:lower:]')
        ICON_PATH_SIMPLE="../supaflow-www/public/connectors/${ICON_NAME_SIMPLE}.svg"

        if [ -f "$ICON_PATH_SIMPLE" ]; then
            echo "✓ Found icon: connectors/${ICON_NAME_SIMPLE}.svg"
            ICON_FOUND="yes"
        else
            # Try base name (e.g., oracle from OracleTM, salesforce from SalesforceMarketingCloud)
            # Extract first word by splitting on uppercase
            ICON_NAME_BASE=$(echo "$CONNECTOR_DISPLAY_NAME" | sed 's/\([A-Z][a-z]*\).*/\1/' | tr '[:upper:]' '[:lower:]')
            ICON_PATH_BASE="../supaflow-www/public/connectors/${ICON_NAME_BASE}.svg"

            if [ -f "$ICON_PATH_BASE" ]; then
                echo "✓ Found base icon: connectors/${ICON_NAME_BASE}.svg"
                echo "   ℹ️  Consider creating specific icon: connectors/${ICON_NAME}.svg"
                ICON_FOUND="yes"
            fi
        fi
    fi

    if [ -z "$ICON_FOUND" ]; then
        echo "⚠️  WARNING: No icon found at expected locations:"
        echo "   → Checked: connectors/${ICON_NAME}.svg"
        echo "   → Checked: connectors/${ICON_NAME_SIMPLE}.svg"
        echo "   → Use placeholder icon or create new SVG"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

echo ""

# ==============================================================================
# CHECK 12: Primary Key and Cursor Field Identification
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 12: Primary Key and Cursor Field Identification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if this is a JDBC connector (extends BaseJdbcConnector)
if $IS_JDBC_CONNECTOR; then
    echo "ℹ️  JDBC connector - BaseJdbcConnector handles PK/cursor identification"
    echo "✓ Primary key identification handled by base class"
    echo "✓ Cursor field identification handled by base class"
else
    # REST connector - check for primary key identification
    echo "ℹ️  REST connector - checking PK/cursor identification"

    # Check for primary key setting - check main file AND helper classes
    # Pattern: setPrimaryKey( with true OR conditional expression
    if grep -q "\.setPrimaryKey(" "$CONNECTOR_FILE"; then
        echo "✓ Found setPrimaryKey() call"

        # Also check for setSourcePrimaryKey (MUST be set together)
        if grep -q "\.setSourcePrimaryKey(" "$CONNECTOR_FILE"; then
            echo "✓ Found setSourcePrimaryKey() call"
        else
            echo "❌ ERROR: setPrimaryKey() found but missing setSourcePrimaryKey()"
            echo "   → You MUST set BOTH setPrimaryKey() AND setSourcePrimaryKey()"
            echo "   → See skill section 4.1.5: Primary Key Identification"
            ERRORS=$((ERRORS + 1))
        fi
    else
        # Check helper classes (SchemaBuilder, MetadataUtil, etc.)
        HELPER_PK=$(grep -rl "\.setPrimaryKey(" "$CONNECTOR_SRC_DIR" 2>/dev/null | head -1 || true)
        if [[ -n "$HELPER_PK" ]]; then
            echo "✓ Found setPrimaryKey() in helper class"
            echo "   → $(basename "$HELPER_PK")"

            # Check for setSourcePrimaryKey in same helper
            if grep -q "\.setSourcePrimaryKey(" "$HELPER_PK"; then
                echo "✓ Found setSourcePrimaryKey() in helper class"
            else
                echo "⚠️  WARNING: setPrimaryKey found but missing setSourcePrimaryKey in helper"
                WARNINGS=$((WARNINGS + 1))
            fi
        else
            echo "⚠️  WARNING: No setPrimaryKey() found"
            echo "   → Connectors should identify primary key fields"
            echo "   → Required for merge operations and deduplication"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    # Check for cursor field identification - supports three patterns:
    # Pattern 1: identifyCursorFields() method with proper implementation
    # Pattern 2: Inline cursor setting during schema building (setCursorField(true) directly)
    # Pattern 3: Utility class delegation (SomeUtil.identifyCursorFields())
    CURSOR_METHOD=$(grep -A20 'public void identifyCursorFields' "$CONNECTOR_FILE" 2>/dev/null || true)
    HAS_INLINE_CURSOR=$(grep -q "setCursorField(true)" "$CONNECTOR_FILE" && echo "yes" || echo "no")
    # Check for utility class delegation (e.g., SalesforceMetadataUtil.identifyCursorFields)
    HAS_UTIL_DELEGATION=$(echo "$CURSOR_METHOD" | grep -q '[A-Z][a-zA-Z]*Util\.\|[A-Z][a-zA-Z]*Helper\.' && echo "yes" || echo "no")

    if [[ -n "$CURSOR_METHOD" ]]; then
        # Has identifyCursorFields() method - check implementation
        if echo "$CURSOR_METHOD" | grep -q 'setCursorField\|setSourceCursorField'; then
            echo "✓ identifyCursorFields() has proper implementation"

            # Check for all three required settings
            if echo "$CURSOR_METHOD" | grep -q 'setCursorField(true)'; then
                echo "✓ Sets setCursorField(true)"
            else
                echo "⚠️  WARNING: identifyCursorFields() may not set setCursorField(true)"
                WARNINGS=$((WARNINGS + 1))
            fi

            if echo "$CURSOR_METHOD" | grep -q 'setSourceCursorField(true)'; then
                echo "✓ Sets setSourceCursorField(true)"
            else
                echo "⚠️  WARNING: identifyCursorFields() may not set setSourceCursorField(true)"
                WARNINGS=$((WARNINGS + 1))
            fi

            if echo "$CURSOR_METHOD" | grep -q 'setCursorFieldLocked(true)'; then
                echo "✓ Sets setCursorFieldLocked(true)"
            else
                echo "⚠️  WARNING: identifyCursorFields() may not set setCursorFieldLocked(true)"
                WARNINGS=$((WARNINGS + 1))
            fi
        elif [[ "$HAS_UTIL_DELEGATION" == "yes" ]]; then
            # Delegates to utility class
            UTIL_NAME=$(echo "$CURSOR_METHOD" | grep -oE '[A-Z][a-zA-Z]*Util\.|[A-Z][a-zA-Z]*Helper\.' | head -1 | tr -d '.')
            echo "✓ identifyCursorFields() delegates to utility class"
            echo "   → Implementation in ${UTIL_NAME}"
        else
            # identifyCursorFields() exists but might delegate or log
            if [[ "$HAS_INLINE_CURSOR" == "yes" ]]; then
                echo "✓ Uses INLINE cursor field setting pattern"
                echo "   → setCursorField() called directly during schema building"
            else
                # Check if it just logs and returns (empty implementation)
                if echo "$CURSOR_METHOD" | grep -vE '^\s*//' | grep -q 'log\.\|return;'; then
                    echo "❌ ERROR: identifyCursorFields() appears to be empty/no-op"
                    echo "   → An empty identifyCursorFields() means NO incremental sync support"
                    echo "   → Must implement cursor field detection or mark objects as skipped"
                    echo "   → See skill section 4.2: Cursor Field Identification patterns"
                    ERRORS=$((ERRORS + 1))
                else
                    echo "⚠️  WARNING: Could not verify identifyCursorFields() implementation"
                    WARNINGS=$((WARNINGS + 1))
                fi
            fi
        fi
    elif [[ "$HAS_INLINE_CURSOR" == "yes" ]]; then
        # No identifyCursorFields() method, but has inline cursor setting
        echo "✓ Uses INLINE cursor field setting pattern"
        echo "   → setCursorField() called directly during schema building"

        # Verify accompanying fields
        if grep -q "setSourceCursorField(true)" "$CONNECTOR_FILE"; then
            echo "✓ Found setSourceCursorField(true)"
        else
            echo "⚠️  WARNING: Missing setSourceCursorField(true) with inline pattern"
            WARNINGS=$((WARNINGS + 1))
        fi

        if grep -q "setCursorFieldLocked(true)" "$CONNECTOR_FILE"; then
            echo "✓ Found setCursorFieldLocked(true)"
        else
            echo "⚠️  WARNING: Missing setCursorFieldLocked(true) with inline pattern"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo "⚠️  WARNING: No cursor field identification found"
        echo "   → No identifyCursorFields() method and no inline setCursorField()"
        echo "   → Connector will be full-refresh only (no incremental sync)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

echo ""

# ==============================================================================
# CHECK 13: Cursor Field Setting Invoked in schema() (CRITICAL)
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 13: Cursor Field Setting Invoked in schema()"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# JDBC connectors inherit this from BaseJdbcConnector
if $IS_JDBC_CONNECTOR; then
    echo "ℹ️  JDBC connector - BaseJdbcConnector handles cursor field identification"
else
    # REST connector - supports multiple patterns:
    # 1. identifyCursorFields() method called in schema()
    # 2. Utility class: SomeUtil.identifyCursorFields()
    # 3. Inline: setCursorField(true) directly during schema building

    HAS_CURSOR_METHOD=$(grep -q "identifyCursorFields(" "$CONNECTOR_FILE" && echo "yes" || echo "no")
    HAS_INLINE_CURSOR=$(grep -rq "setCursorField(true)" "$CONNECTOR_CLASS_DIR"/ --include="*.java" 2>/dev/null && echo "yes" || echo "no")

    if [[ "$HAS_CURSOR_METHOD" == "yes" ]]; then
        # Check if it's actually CALLED (not just defined)
        # Look for calls like: identifyCursorFields(metadata) or Util.identifyCursorFields(obj)
        CURSOR_CALLS=$(grep -n "identifyCursorFields(" "$CONNECTOR_FILE" | grep -v "public void identifyCursorFields" | grep -v "^\s*//" || true)

        if [[ -n "$CURSOR_CALLS" ]]; then
            echo "✓ identifyCursorFields() is called in the code"
            echo "   Found at:"
            echo "$CURSOR_CALLS" | head -3 | while read -r line; do
                echo "   $line"
            done
        elif [[ "$HAS_INLINE_CURSOR" == "yes" ]]; then
            # identifyCursorFields() method exists but not called - check for inline pattern
            echo "✓ Uses INLINE cursor field setting (alternative pattern)"
            echo "   → setCursorField() called directly during schema building"
        else
            echo "❌ ERROR: identifyCursorFields() method EXISTS but is NEVER CALLED"
            echo "   → The method is defined but not invoked in schema()"
            echo "   → Incremental sync will be dead code - no cursor fields marked"
            echo "   → Fix by EITHER:"
            echo "     1. Add: identifyCursorFields(objectMetadata) in buildObjectMetadata()"
            echo "     2. Or set cursor fields inline during field building"
            ERRORS=$((ERRORS + 1))
        fi
    elif [[ "$HAS_INLINE_CURSOR" == "yes" ]]; then
        # No identifyCursorFields() but has inline cursor setting
        echo "✓ Uses INLINE cursor field setting pattern"
        echo "   → setCursorField() called directly during schema building"
    else
        echo "⚠️  WARNING: No cursor field identification found"
        echo "   → No identifyCursorFields() and no inline setCursorField()"
        echo "   → Connector will be full-refresh only (no incremental sync)"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

echo ""

# ==============================================================================
# CHECK 14: Build Artifacts Not Committed
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 14: Build Artifacts Not Committed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if target/ directory exists and is tracked by git
if [ -d "$CONNECTOR_DIR/target" ]; then
    # Check if target is in git
    if git ls-files --error-unmatch "$CONNECTOR_DIR/target" >/dev/null 2>&1 || \
       [ -n "$(git ls-files "$CONNECTOR_DIR/target" 2>/dev/null)" ]; then
        echo "❌ ERROR: target/ directory is committed to git"
        echo "   → Build artifacts should not be in version control"
        echo "   → Remove with: git rm -r --cached $CONNECTOR_DIR/target"
        echo "   → Add to .gitignore: target/"
        ERRORS=$((ERRORS + 1))
    else
        echo "✓ target/ directory exists but not in git (correct)"
    fi
else
    echo "✓ No target/ directory found (clean checkout)"
fi

echo ""

# ==============================================================================
# CHECK 15: Integration Tests Exist
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 15: Integration Tests Exist"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# IT_TEST_FILE already set earlier (line 93)
if [[ -n "$IT_TEST_FILE" ]]; then
    echo "✓ Found IT test: $(basename "$IT_TEST_FILE")"

    # Check for required test annotations
    if grep -q "@TestInstance.*PER_CLASS" "$IT_TEST_FILE"; then
        echo "✓ Has @TestInstance(PER_CLASS) annotation"
    else
        echo "⚠️  WARNING: Missing @TestInstance(Lifecycle.PER_CLASS)"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -q "@TestMethodOrder" "$IT_TEST_FILE"; then
        echo "✓ Has @TestMethodOrder annotation"
    else
        echo "⚠️  WARNING: Missing @TestMethodOrder(OrderAnnotation.class)"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Check for required tests
    if grep -q "testConnectorInitialized\|testInit" "$IT_TEST_FILE"; then
        echo "✓ Has initialization test"
    else
        echo "⚠️  WARNING: Missing initialization test"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -q "testListObjects\|testSchemaDiscovery\|testSchema" "$IT_TEST_FILE"; then
        echo "✓ Has schema discovery test"
    else
        echo "⚠️  WARNING: Missing schema discovery test"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -q "testReadData\|testRead" "$IT_TEST_FILE"; then
        echo "✓ Has read data test"
    else
        echo "⚠️  WARNING: Missing read data test"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -q "testCursorTracking\|testIncremental" "$IT_TEST_FILE"; then
        echo "✓ Has cursor tracking test"
    else
        echo "⚠️  WARNING: Missing cursor tracking test"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "❌ ERROR: No integration test file found (*ConnectorIT.java)"
    echo "   → Create IT tests following CONNECTOR_TESTING_SKILL.md"
    echo "   → IT tests validate the full connector lifecycle"
    ERRORS=$((ERRORS + 1))
fi

echo ""

fi # End of source checks conditional block

# ==============================================================================
# DESTINATION CONNECTOR CHECKS (16-25)
# Only run if connector declares REPLICATION_DESTINATION capability
# Skip for source-only connectors unless they also have destination capability
# ==============================================================================

# Use the early-detected destination flag
IS_DESTINATION_CONNECTOR=$IS_DESTINATION_CONNECTOR_EARLY

if ! $IS_DESTINATION_CONNECTOR && $IS_SOURCE_CONNECTOR; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⏭  SKIPPING DESTINATION CHECKS (16-24)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "ℹ️  Connector is source-only - destination checks not applicable"
    echo ""
fi

if $IS_DESTINATION_CONNECTOR; then
    echo ""
    echo "==================================================================="
    echo "  DESTINATION CONNECTOR CHECKS"
    echo "==================================================================="
    echo "ℹ️  Detected: Connector has REPLICATION_DESTINATION capability"
    echo ""

    # Detect destination type: Warehouse (has stage) vs Activation (no stage)
    IS_WAREHOUSE_DESTINATION=false
    IS_ACTIVATION_DESTINATION=false

    # Check for stage() implementation
    STAGE_METHOD=$(grep -A5 "public.*StageResponse stage" "$CONNECTOR_FILE" 2>/dev/null || true)
    if [[ -n "$STAGE_METHOD" ]]; then
        if echo "$STAGE_METHOD" | grep -q "UnsupportedOperationException\|throw new"; then
            IS_ACTIVATION_DESTINATION=true
            echo "ℹ️  Destination Type: ACTIVATION (API-based, no staging)"
        else
            IS_WAREHOUSE_DESTINATION=true
            echo "ℹ️  Destination Type: WAREHOUSE (staging + load)"
        fi
    else
        # No stage method found - check if it's inherited or activation
        if grep -q "getActivationTarget\|activationTarget" "$CONNECTOR_FILE"; then
            IS_ACTIVATION_DESTINATION=true
            echo "ℹ️  Destination Type: ACTIVATION (API-based, no staging)"
        else
            IS_WAREHOUSE_DESTINATION=true
            echo "ℹ️  Destination Type: WAREHOUSE (staging + load)"
        fi
    fi
    echo ""

    # ==============================================================================
    # CHECK 16: getCapabilitiesConfig() for Destinations
    # ==============================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✓ CHECK 16: Destination Capabilities Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if grep -q "getCapabilitiesConfig" "$CONNECTOR_FILE"; then
        echo "✓ Found getCapabilitiesConfig() method"

        # Check for load modes
        if grep -q "loadModes\|LoadMode" "$CONNECTOR_FILE"; then
            echo "✓ Defines loadModes"
        else
            echo "⚠️  WARNING: No loadModes defined in capabilities"
            WARNINGS=$((WARNINGS + 1))
        fi

        # Check for destination table handling
        if grep -q "destinationTableHandling\|DestinationTableHandling" "$CONNECTOR_FILE"; then
            echo "✓ Defines destinationTableHandling"
        else
            echo "⚠️  WARNING: No destinationTableHandling defined"
            WARNINGS=$((WARNINGS + 1))
        fi

        # Check for staging configuration
        if $IS_WAREHOUSE_DESTINATION; then
            if grep -q "supportsStaging\|requiresStaging" "$CONNECTOR_FILE"; then
                echo "✓ Defines staging configuration"
            else
                echo "⚠️  WARNING: Warehouse destination should define staging config"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        echo "❌ ERROR: Missing getCapabilitiesConfig() for destination"
        ERRORS=$((ERRORS + 1))
    fi

    echo ""

    # ==============================================================================
    # CHECK 17: mapToTargetObject() Implementation
    # ==============================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✓ CHECK 17: mapToTargetObject() Implementation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if grep -q "public.*ObjectMetadata mapToTargetObject" "$CONNECTOR_FILE"; then
        echo "✓ Found mapToTargetObject() method"

        # Check that NamespaceRules is actually USED (not just a parameter)
        if grep -q "namespaceRules\.get\|namespaceRules\.apply\|getTableName\|getSchemaName\|getDatabaseName" "$CONNECTOR_FILE"; then
            echo "✓ Applies NamespaceRules (pipeline prefix)"
        else
            echo "❌ ERROR: mapToTargetObject() does not apply NamespaceRules"
            echo "   → Must call namespaceRules.getTableName/getSchemaName/getDatabaseName"
            echo "   → Pipeline prefix will not be applied"
            ERRORS=$((ERRORS + 1))
        fi

        # Check that tracking columns are NOT added
        if grep -A 50 "mapToTargetObject" "$CONNECTOR_FILE" | grep -q "_supa_synced\|_supa_sync_id\|_supa_deleted"; then
            echo "❌ ERROR: mapToTargetObject() adds tracking columns"
            echo "   → DO NOT add _supa_* columns in mapToTargetObject()"
            echo "   → Writer/schema mapper adds them automatically"
            echo "   → Adding them here causes duplicates"
            ERRORS=$((ERRORS + 1))
        else
            echo "✓ Does not add tracking columns (correct)"
        fi

        # Check customAttributes preservation
        if grep -A 50 "mapToTargetObject" "$CONNECTOR_FILE" | grep -q "setCustomAttributes\|customAttributes"; then
            echo "✓ Preserves customAttributes (sync metadata)"
        else
            echo "⚠️  WARNING: May not preserve customAttributes"
            echo "   → Should copy sourceObj.getCustomAttributes() to destination"
            echo "   → Contains supa_sync_time and other metadata"
            WARNINGS=$((WARNINGS + 1))
        fi

        if $IS_WAREHOUSE_DESTINATION; then
            # Warehouse: Check NamespaceRules usage
            if grep -q "NamespaceRules\|namespaceRules" "$CONNECTOR_FILE"; then
                echo "✓ Uses NamespaceRules for schema mapping"
            else
                echo "⚠️  WARNING: Warehouse destination should use NamespaceRules"
                WARNINGS=$((WARNINGS + 1))
            fi
        else
            # Activation: Should preserve activation metadata
            if grep -q "getActivationTarget\|activationTarget" "$CONNECTOR_FILE"; then
                echo "✓ Handles activation_target metadata"
            else
                echo "⚠️  WARNING: Activation destination should handle activation_target"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        echo "❌ ERROR: Missing mapToTargetObject() method"
        echo "   → Required for destination connectors"
        ERRORS=$((ERRORS + 1))
    fi

    echo ""

    # ==============================================================================
    # CHECK 18: load() Implementation
    # ==============================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✓ CHECK 18: load() Implementation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check main connector file and helper classes (search recursively)
    LOAD_METHOD=$(grep -rl "public.*LoadResponse load" "$CONNECTOR_SRC_DIR" --include="*.java" 2>/dev/null | head -1 || true)
    if [[ -n "$LOAD_METHOD" ]]; then
        echo "✓ Found load() method in $(basename "$LOAD_METHOD")"

        # Check for LoadRequest usage
        if grep -q "LoadRequest" "$LOAD_METHOD"; then
            echo "✓ Uses LoadRequest parameter"
        fi

        # Check for callback usage
        if grep -q "getCallback\|\.callback\|request\.getCallback" "$LOAD_METHOD"; then
            echo "✓ Uses callback for progress reporting"
        else
            echo "⚠️  WARNING: load() should use callback for progress"
            WARNINGS=$((WARNINGS + 1))
        fi

        # Check for metadata mapping usage
        if grep -q "getMetadataMapping\|getMappedMergedSourceMetadata" "$LOAD_METHOD"; then
            echo "✓ Uses metadata mapping"
        else
            echo "⚠️  WARNING: load() should use metadataMapping"
            WARNINGS=$((WARNINGS + 1))
        fi

        if $IS_WAREHOUSE_DESTINATION; then
            # Warehouse-specific checks
            if grep -q "getStageLocation\|stageLocation" "$LOAD_METHOD"; then
                echo "✓ Handles stageLocation"
            fi

            if grep -q "getLoadMode\|LoadMode" "$LOAD_METHOD"; then
                echo "✓ Handles LoadMode"
            else
                echo "⚠️  WARNING: Warehouse destination should handle LoadMode"
                WARNINGS=$((WARNINGS + 1))
            fi
        else
            # Activation-specific checks
            if grep -q "getLocalDataPath\|localDataPath" "$LOAD_METHOD"; then
                echo "✓ Uses localDataPath for direct loading"
            else
                echo "⚠️  WARNING: Activation destination should use localDataPath"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        echo "❌ ERROR: Missing load() method"
        echo "   → Required for destination connectors"
        ERRORS=$((ERRORS + 1))
    fi

    echo ""

    # ==============================================================================
    # CHECK 19: stage() Implementation (Warehouse) or No-Op (Activation)
    # ==============================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✓ CHECK 19: stage() Implementation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    STAGE_FILE=$(grep -rl "public.*StageResponse stage" "$CONNECTOR_SRC_DIR" --include="*.java" 2>/dev/null | head -1 || true)
    if [[ -n "$STAGE_FILE" ]]; then
        if $IS_WAREHOUSE_DESTINATION; then
            echo "✓ Found stage() implementation"

            if grep -q "StageResponse.success\|return.*StageResponse" "$STAGE_FILE"; then
                echo "✓ Returns StageResponse"
            fi

            # CRITICAL: Check for correct CSV file pattern
            if grep -q "success_part_" "$STAGE_FILE"; then
                echo "✓ Uses correct CSV file pattern (success_part_*.csv)"
            else
                echo "⚠️  WARNING: stage() may not use correct CSV file pattern"
                echo "   → Platform writes: success_part_*.csv (not <table>_*.csv)"
                echo "   → Should filter for files starting with 'success_part_'"
                WARNINGS=$((WARNINGS + 1))
            fi

            # Check that it doesn't look for wrong patterns
            if grep -A30 "public.*StageResponse stage" "$STAGE_FILE" | grep -q "tableName.*_\|tableName + \"_\""; then
                echo "⚠️  WARNING: stage() may be using wrong file pattern (<table>_*.csv)"
                echo "   → This will find zero files in production"
                WARNINGS=$((WARNINGS + 1))
            fi
        else
            # Activation should throw or return no-op
            if grep -A10 "public.*StageResponse stage" "$STAGE_FILE" | grep -q "UnsupportedOperationException\|throw new\|not supported"; then
                echo "✓ stage() correctly throws UnsupportedOperationException"
            else
                echo "⚠️  WARNING: Activation destination should throw UnsupportedOperationException in stage()"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        if $IS_WAREHOUSE_DESTINATION; then
            echo "⚠️  WARNING: Warehouse destination missing stage() method"
            WARNINGS=$((WARNINGS + 1))
        else
            echo "✓ No stage() method (correct for activation destination)"
        fi
    fi

    echo ""

    # ==============================================================================
    # ACTIVATION-SPECIFIC CHECKS (20-23)
    # ==============================================================================
    if $IS_ACTIVATION_DESTINATION; then
        # CHECK 20: activation_target handling
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 20: Activation Target Handling"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if grep -rq "getActivationTarget\|\.getActivationTarget()" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Extracts activation_target from metadata"
        else
            echo "❌ ERROR: Missing activation_target handling"
            echo "   → Must call metadata.getActivationTarget() to get destination object"
            ERRORS=$((ERRORS + 1))
        fi

        echo ""

        # CHECK 21: activation_target_field usage
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 21: Activation Target Field Mapping"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if grep -rq "getActivationTargetField\|activation_target_field" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Uses activation_target_field for field mapping"
        else
            echo "❌ ERROR: Missing activation_target_field handling"
            echo "   → Must use field.getActivationTargetField() to map source→destination"
            ERRORS=$((ERRORS + 1))
        fi

        echo ""

        # CHECK 22: selected_merge_keys handling
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 22: Merge Keys Handling"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if grep -rq "getSelectedMergeKeys\|selected_merge_keys\|externalIdField\|mergeKeys" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Handles selected_merge_keys for upsert"
        else
            echo "⚠️  WARNING: Missing selected_merge_keys handling"
            echo "   → Should use for upsert external ID field"
            WARNINGS=$((WARNINGS + 1))
        fi

        echo ""

        # CHECK 23: Error/Success record processors
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 23: Error/Success Record Processors"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if grep -rq "ErrorRecordProcessor\|errorRecordProcessor\|getErrorRecordProcessor" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Supports error record processor"
        else
            echo "⚠️  WARNING: Missing error record processor support"
            echo "   → Activation connectors should report per-record errors"
            WARNINGS=$((WARNINGS + 1))
        fi

        if grep -rq "SuccessRecordProcessor\|successRecordProcessor\|getSuccessRecordProcessor" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Supports success record processor"
        else
            echo "⚠️  WARNING: Missing success record processor support"
            WARNINGS=$((WARNINGS + 1))
        fi

        echo ""
    fi

    # ==============================================================================
    # WAREHOUSE-SPECIFIC CHECKS (20-23)
    # ==============================================================================
    if $IS_WAREHOUSE_DESTINATION; then
        # CHECK 20: COPY INTO / Staging load
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 20: Staging Load Implementation"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if grep -rq "COPY INTO\|executeCopyInto\|copyInto" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Found COPY INTO implementation"
        else
            if grep -rq "uploadToStage\|PUT.*stage\|stageLocation" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
                echo "✓ Found staging upload implementation"
            else
                echo "⚠️  WARNING: No COPY INTO or staging implementation found"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi

        echo ""

        # CHECK 21: MERGE implementation
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 21: MERGE Implementation"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if grep -rq "MERGE INTO\|executeMerge\|buildMergeSql" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Found MERGE implementation"
        else
            echo "⚠️  WARNING: No MERGE implementation found"
            echo "   → Required for LoadMode.MERGE support"
            WARNINGS=$((WARNINGS + 1))
        fi

        echo ""

        # CHECK 22: LoadMode handling
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 22: LoadMode Handling"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        LOAD_MODES_HANDLED=0
        if grep -rq "LoadMode.APPEND\|APPEND" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Handles LoadMode.APPEND"
            LOAD_MODES_HANDLED=$((LOAD_MODES_HANDLED + 1))
        fi
        if grep -rq "LoadMode.MERGE\|case MERGE" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Handles LoadMode.MERGE"
            LOAD_MODES_HANDLED=$((LOAD_MODES_HANDLED + 1))
        fi
        if grep -rq "LoadMode.OVERWRITE\|OVERWRITE" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Handles LoadMode.OVERWRITE"
            LOAD_MODES_HANDLED=$((LOAD_MODES_HANDLED + 1))
        fi
        if grep -rq "LoadMode.TRUNCATE_AND_LOAD\|TRUNCATE_AND_LOAD" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Handles LoadMode.TRUNCATE_AND_LOAD"
            LOAD_MODES_HANDLED=$((LOAD_MODES_HANDLED + 1))
        fi

        if [ $LOAD_MODES_HANDLED -eq 0 ]; then
            echo "⚠️  WARNING: No LoadMode handling found"
            WARNINGS=$((WARNINGS + 1))
        fi

        echo ""

        # CHECK 23: DDL Generation
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 23: DDL Generation"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if grep -rq "CREATE TABLE\|createTable\|buildCreateTableSql" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Found CREATE TABLE implementation"
        else
            echo "⚠️  WARNING: No CREATE TABLE implementation found"
            WARNINGS=$((WARNINGS + 1))
        fi

        if grep -rq "ALTER TABLE\|alterTable\|buildAlterTableSql" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Found ALTER TABLE implementation (schema evolution)"
        else
            echo "ℹ️  No ALTER TABLE found (may not support schema evolution)"
        fi

        echo ""
    fi

    # ==============================================================================
    # CHECK 24: Destination Integration Tests
    # ==============================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✓ CHECK 24: Destination Integration Tests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ -n "$IT_TEST_FILE" ]]; then
        # Check for destination-specific tests
        if grep -q "testLoad\|testWrite\|testUpsert" "$IT_TEST_FILE" 2>/dev/null; then
            echo "✓ Has load/write test"
        else
            echo "⚠️  WARNING: Missing load/write test in IT"
            WARNINGS=$((WARNINGS + 1))
        fi

        # CRITICAL: Check for realistic test data (not simplified)
        if grep -q "success_part_" "$IT_TEST_FILE"; then
            echo "✓ Uses realistic CSV file patterns (success_part_*.csv)"
        else
            echo "⚠️  WARNING: IT tests may use simplified CSV file names"
            echo "   → Should use production patterns: success_part_*.csv"
            echo "   → Simplified names don't catch CSV discovery issues"
            WARNINGS=$((WARNINGS + 1))
        fi

        # Check for namespace prefix validation
        if grep -q "pipelinePrefix\|pipeline_prefix\|namespace.*prefix" "$IT_TEST_FILE"; then
            echo "✓ Tests namespace prefix application"
        else
            echo "⚠️  WARNING: IT tests may not verify namespace prefix"
            echo "   → Should test that mapToTargetObject() applies pipeline prefix"
            WARNINGS=$((WARNINGS + 1))
        fi

        if $IS_WAREHOUSE_DESTINATION; then
            if grep -q "testStage\|testCopyInto\|testMerge" "$IT_TEST_FILE" 2>/dev/null; then
                echo "✓ Has staging/merge test"
            else
                echo "⚠️  WARNING: Missing staging/merge test for warehouse"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi

        if $IS_ACTIVATION_DESTINATION; then
            if grep -q "testActivation\|testUpsert\|testApiWrite" "$IT_TEST_FILE" 2>/dev/null; then
                echo "✓ Has activation/upsert test"
            else
                echo "⚠️  WARNING: Missing activation test"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        echo "⚠️  WARNING: No IT test file found for destination tests"
        WARNINGS=$((WARNINGS + 1))
    fi

    echo ""
fi

# ==============================================================================
# CHECK 25: Parent POM Module Registration (CRITICAL)
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 25: Parent POM Module Registration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

PARENT_POM="./pom.xml"
MODULE_ENTRY="<module>connectors/supaflow-connector-${CONNECTOR_NAME}</module>"

if [ -f "$PARENT_POM" ]; then
    if grep -q "$MODULE_ENTRY" "$PARENT_POM"; then
        echo "✓ Connector registered in parent pom.xml"

        # Verify reactor build includes this module (if mvn available)
        if command -v mvn >/dev/null 2>&1; then
            echo "  → Verifying reactor build..."
            BUILD_OUTPUT=$(mvn clean compile -pl "connectors/supaflow-connector-${CONNECTOR_NAME}" -am -q 2>&1)
            if echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCESS"; then
                echo "✓ Reactor build includes connector (verified)"
            else
                echo "⚠️  WARNING: Reactor build may have issues"
                echo "  → Try: mvn clean compile -pl connectors/supaflow-connector-${CONNECTOR_NAME} -am"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        echo "❌ ERROR: Connector NOT registered in parent pom.xml"
        echo "   → Add to $PARENT_POM in <modules> section:"
        echo "   → $MODULE_ENTRY"
        echo "   → Location: After similar connectors (databases, warehouses, etc.)"
        echo ""
        echo "   Without this registration:"
        echo "   • mvn clean install (from root) will skip this connector"
        echo "   • Agent deployments won't include this connector"
        echo "   • Production builds will be missing this connector"
        echo ""
        echo "   Verification after adding:"
        echo "   mvn clean compile -pl connectors/supaflow-connector-${CONNECTOR_NAME} -am"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "⚠️  WARNING: Could not find parent pom.xml at $PARENT_POM"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# ==============================================================================
# CHECK 26: Dependency Version Management
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 26: Dependency Version Management"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check for common dependencies that should use parent versions
PARENT_MANAGED_DEPS=(
    "commons-codec"
    "commons-io"
    "opencsv"
    "slf4j-api"
)

HARDCODED_VERSIONS=""
for dep in "${PARENT_MANAGED_DEPS[@]}"; do
    # Check if dependency exists with explicit version
    if grep -A2 "artifactId>$dep<" "$CONNECTOR_DIR/pom.xml" | grep -q "<version>"; then
        VERSION=$(grep -A2 "artifactId>$dep<" "$CONNECTOR_DIR/pom.xml" | grep "<version>" | sed 's/.*<version>\(.*\)<\/version>.*/\1/')
        HARDCODED_VERSIONS="$HARDCODED_VERSIONS\n  • $dep: $VERSION (should use parent)"
    fi
done

if [[ -n "$HARDCODED_VERSIONS" ]]; then
    echo "⚠️  WARNING: Dependencies with hardcoded versions found:"
    echo -e "$HARDCODED_VERSIONS"
    echo ""
    echo "   These dependencies are managed by parent POM."
    echo "   Remove <version> tag to use parent version."
    echo ""
    echo "   Check parent versions:"
    echo "   grep -A3 'artifactId>commons-codec' ../../pom.xml"
    WARNINGS=$((WARNINGS + 1))
else
    echo "✓ No hardcoded versions for parent-managed dependencies"
fi

# Check for internal module dependencies with explicit versions (in <dependencies> section only)
# Extract just the dependencies section and check there
DEPS_SECTION=$(awk '/<dependencies>/,/<\/dependencies>/' "$CONNECTOR_DIR/pom.xml")
if echo "$DEPS_SECTION" | grep -A2 "groupId>io.supaflow<" | grep -q "<version>"; then
    # Found internal dependency with version - extract which one
    INTERNAL_DEPS_WITH_VERSION=$(echo "$DEPS_SECTION" | grep -B1 -A2 "groupId>io.supaflow<" | grep -B1 "<version>" | grep "artifactId" | sed 's/.*<artifactId>\(.*\)<\/artifactId>.*/\1/' | head -1)
    echo "⚠️  WARNING: Internal Supaflow modules should NOT have explicit versions"
    echo "   → Found: $INTERNAL_DEPS_WITH_VERSION"
    echo "   → Remove <version> from io.supaflow dependencies"
    echo "   → They inherit \${project.version} from parent"
    WARNINGS=$((WARNINGS + 1))
else
    echo "✓ Internal modules use inherited version"
fi

echo ""

# ==============================================================================
# CHECK 27: Cancellation Support (CRITICAL)
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 27: Cancellation Support"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if $IS_JDBC_CONNECTOR; then
    echo "ℹ️  JDBC connector - BaseJdbcConnector provides cancellation support"
    echo "✓ Cancellation wiring inherited from base class"
else
    # REST connector - check for cancellation wiring
    HAS_CANCEL_SUPPLIER=$(grep -q "cancellationSupplier\|BooleanSupplier" "$CONNECTOR_FILE" && echo "yes" || echo "no")
    HAS_CANCEL_METHOD=$(grep -rq "checkCancellation" "$CONNECTOR_CLASS_DIR"/ --include="*.java" 2>/dev/null && echo "yes" || echo "no")

    if [[ "$HAS_CANCEL_SUPPLIER" == "yes" ]]; then
        echo "✓ Found cancellationSupplier field"

        # Check if it's wired from runtimeContext
        if grep -q "getCancellationSupplier()" "$CONNECTOR_FILE"; then
            echo "✓ Wired from runtimeContext.getCancellationSupplier()"
        else
            echo "⚠️  WARNING: cancellationSupplier field exists but may not be wired from context"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo "❌ ERROR: Missing cancellationSupplier field"
        echo "   → Add: private volatile BooleanSupplier cancellationSupplier = () -> false;"
        echo "   → Wire in setRuntimeContext(): this.cancellationSupplier = context.getCancellationSupplier();"
        ERRORS=$((ERRORS + 1))
    fi

    if [[ "$HAS_CANCEL_METHOD" == "yes" ]]; then
        echo "✓ Found checkCancellation() method"
    else
        echo "❌ ERROR: Missing checkCancellation() helper method"
        echo "   → Add method to check cancellation and throw ConnectorException.CANCELLED"
        ERRORS=$((ERRORS + 1))
    fi

    # Check for loops that should have cancellation checks
    # Look for while/for loops that might be pagination or data processing
    HAS_WHILE_LOOPS=$(grep -E -c "while[[:space:]]*\(" "$CONNECTOR_FILE" 2>/dev/null)
    HAS_FOR_LOOPS=$(grep -E -c "for[[:space:]]*\(" "$CONNECTOR_FILE" 2>/dev/null)
    TOTAL_LOOPS=$((HAS_WHILE_LOOPS + HAS_FOR_LOOPS))

    if [ $TOTAL_LOOPS -gt 0 ]; then
        echo "ℹ️  Found $TOTAL_LOOPS loop(s) in connector"

        # Count checkCancellation calls
        CANCEL_CHECKS=$(grep -rc "checkCancellation\|checkCancellationPublic" "$CONNECTOR_CLASS_DIR"/ --include="*.java" 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')

        if [ "$CANCEL_CHECKS" -eq 0 ]; then
            echo "⚠️  WARNING: No checkCancellation() calls found in connector with loops"
            echo "   → Long-running loops should check cancellation periodically"
            echo "   → Add checkCancellation() in pagination loops, retry loops, and data processing"
            WARNINGS=$((WARNINGS + 1))
        else
            echo "✓ Found $CANCEL_CHECKS cancellation check(s)"
        fi
    else
        echo "ℹ️  No explicit loops found (may use functional iteration)"
    fi
fi

# Check for CANCELLED exception handling (applies to all connectors)
HAS_CANCELLED_CHECK=$(grep -q "ErrorType\.CANCELLED\|CANCELLED" "$CONNECTOR_FILE" && echo "yes" || echo "no")
if [[ "$HAS_CANCELLED_CHECK" == "yes" ]]; then
    # Check if CANCELLED is being retried (anti-pattern)
    # Look for retry/continue/break near CANCELLED that aren't followed by throw/rethrow
    if grep -B5 -A5 "ErrorType\.CANCELLED\|CANCELLED" "$CONNECTOR_FILE" | grep -E "retry|continue|break" | grep -Ev "throw|rethrow" > /dev/null 2>&1; then
        echo "⚠️  WARNING: CANCELLED exception may be retried or suppressed"
        echo "   → Never retry ConnectorException.ErrorType.CANCELLED"
        echo "   → Always rethrow cancellation exceptions immediately"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "✓ CANCELLED exception handling appears correct"
    fi
fi

echo ""

# ==============================================================================
# Summary
# ==============================================================================
echo "==================================================================="
echo "  VERIFICATION SUMMARY"
echo "==================================================================="
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "✅ SUCCESS: All checks passed!"
    echo ""
    echo "The connector implementation looks correct and complete."
    echo "Proceed with testing: mvn clean verify"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo "⚠️  WARNINGS FOUND: $WARNINGS warning(s)"
    echo ""
    echo "The connector has minor issues that should be reviewed."
    echo "Review warnings above and fix before production use."
    exit 0
else
    echo "❌ ERRORS FOUND: $ERRORS error(s), $WARNINGS warning(s)"
    echo ""
    echo "The connector has critical issues that MUST be fixed."
    echo "Review errors above and correct implementation."
    echo ""
    echo "Common fixes:"
    echo "  • Add processor.completeProcessing() before building ReadResponse"
    echo "  • Use SyncStateResponseBuilder.fromProcessingResult()"
    echo "  • Do NOT call processor.close() - pipeline manages lifecycle"
    echo "  • Use setDatasourceProductName() not setStatus()"
    echo "  • Use ConnectorCapabilities.REPLICATION_SOURCE not .READ"
    echo "  • Call identifyCursorFields() in schema() for incremental sync"
    echo ""
    exit 1
fi
