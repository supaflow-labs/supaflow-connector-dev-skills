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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$PLATFORM_ROOT" ]; then
    echo "ERROR: Platform root does not exist: $PLATFORM_ROOT"
    exit 1
fi

if [ ! -f "$PLATFORM_ROOT/pom.xml" ] || [ ! -d "$PLATFORM_ROOT/connectors" ]; then
    echo "ERROR: Platform root must contain pom.xml and connectors/: $PLATFORM_ROOT"
    exit 1
fi

cd "$PLATFORM_ROOT" || exit 1

# Python/dlt connectors live outside the Java Maven module tree. Route them to
# the AST + behavioral-test-evidence verifier before applying Java-only checks.
PYTHON_CONNECTOR_NAME="${CONNECTOR_NAME//-/_}"
PYTHON_CONNECTOR_FILE="python/connectors/supaflow_connector_${PYTHON_CONNECTOR_NAME}/connector.py"
if [ -f "$PYTHON_CONNECTOR_FILE" ]; then
    PYTHON_BIN="python/.venv/bin/python"
    if [ ! -x "$PYTHON_BIN" ]; then
        PYTHON_BIN="python3"
    fi
    exec "$PYTHON_BIN" \
        "$SCRIPT_DIR/verify_python_dlt_connector.py" \
        "$PYTHON_CONNECTOR_NAME" \
        "$PLATFORM_ROOT"
fi

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
JAVA_EVIDENCE_VERIFIER="$SCRIPT_DIR/verify_java_contract_evidence.py"

run_java_evidence_check() {
    local check_name="$1"
    local success_message="$2"
    local output
    local failure_count

    if output=$(python3 "$JAVA_EVIDENCE_VERIFIER" \
            "$check_name" "$CONNECTOR_NAME" "$PLATFORM_ROOT" 2>&1); then
        echo "✓ $success_message"
        return
    fi

    printf '%s\n' "$output" | sed 's/^FAIL: /❌ ERROR: /'
    failure_count=$(printf '%s\n' "$output" | grep -c '^FAIL:' || true)
    if [ "$failure_count" -eq 0 ]; then
        failure_count=1
    fi
    ERRORS=$((ERRORS + failure_count))
}

resolve_java_string_return() {
    local method_name="$1"
    local return_expression
    local constant_name
    local constant_class
    local constant_file
    local resolved

    return_expression=$(grep -A4 "public String ${method_name}()" "$CONNECTOR_FILE" \
        | grep 'return' | head -1 \
        | sed 's/.*return[[:space:]]*//; s/[[:space:]]*;.*//')
    if [[ "$return_expression" =~ ^\"([^\"]*)\"$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
    fi

    constant_name="${return_expression##*.}"
    constant_class=""
    if [[ "$return_expression" == *.* ]]; then
        constant_class="${return_expression%.*}"
    fi

    if [[ -n "$constant_class" ]]; then
        constant_file=$(find "$CONNECTOR_CLASS_DIR" -name "${constant_class}.java" -print -quit)
    fi
    if [[ -z "$constant_file" ]]; then
        constant_file=$(grep -Rl --include="*.java" \
            "static final String[[:space:]]*${constant_name}[[:space:]]*=" \
            "$CONNECTOR_CLASS_DIR" 2>/dev/null | head -1)
    fi
    if [[ -n "$constant_file" ]]; then
        resolved=$(grep \
            "static final String[[:space:]]*${constant_name}[[:space:]]*=" \
            "$constant_file" | head -1 | sed 's/.*=[[:space:]]*"\([^"]*\)".*/\1/')
        printf '%s' "$resolved"
    fi
}

# Detect connector type (JDBC vs REST)
IS_JDBC_CONNECTOR=false
if grep -q "extends BaseJdbcConnector" "$CONNECTOR_FILE"; then
    IS_JDBC_CONNECTOR=true
    echo "ℹ️  Detected: JDBC Connector (extends BaseJdbcConnector)"
    echo "   → Many methods inherited from base class"
    echo ""
fi

# Detect connector capabilities from active method bodies. Raw grep is unsafe:
# commented-out capabilities previously classified Snowflake as source+activation.
if ! CLASSIFICATION_OUTPUT=$(python3 "$JAVA_EVIDENCE_VERIFIER" \
        classify "$CONNECTOR_NAME" "$PLATFORM_ROOT" 2>&1); then
    echo "❌ ERROR: Could not classify connector capabilities"
    printf '%s\n' "$CLASSIFICATION_OUTPUT"
    exit 1
fi

classification_value() {
    local key="$1"
    printf '%s\n' "$CLASSIFICATION_OUTPUT" \
        | awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

IS_SOURCE_CONNECTOR=$(classification_value source)
IS_DESTINATION_CONNECTOR_EARLY=$(classification_value destination)
IS_ACTIVATION_DESTINATION=$(classification_value activation)
IS_WAREHOUSE_DESTINATION=$(classification_value warehouse)
IS_DIRECT_DATABASE_DESTINATION=$(classification_value direct)
HAS_INVALID_READ_CAPABILITY=$(classification_value invalid_read)
HAS_INVALID_WRITE_CAPABILITY=$(classification_value invalid_write)
HAS_INVALID_SCHEMA_DISCOVERY_CAPABILITY=$(classification_value invalid_schema_discovery)

for classification_flag in \
    IS_SOURCE_CONNECTOR \
    IS_DESTINATION_CONNECTOR_EARLY \
    IS_ACTIVATION_DESTINATION \
    IS_WAREHOUSE_DESTINATION \
    IS_DIRECT_DATABASE_DESTINATION \
    HAS_INVALID_READ_CAPABILITY \
    HAS_INVALID_WRITE_CAPABILITY \
    HAS_INVALID_SCHEMA_DISCOVERY_CAPABILITY; do
    if [[ "${!classification_flag}" != "true" && "${!classification_flag}" != "false" ]]; then
        echo "❌ ERROR: Incomplete connector classification: $classification_flag"
        exit 1
    fi
done

# Display connector purpose
if $IS_SOURCE_CONNECTOR && $IS_DESTINATION_CONNECTOR_EARLY; then
    echo "ℹ️  Detected: DUAL-PURPOSE Connector (source + destination)"
    echo "   → Will run both source and destination checks"
    echo ""
elif $IS_SOURCE_CONNECTOR; then
    echo "ℹ️  Detected: SOURCE-ONLY Connector"
    echo "   → Will skip destination checks"
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
# Find IT test files (used by both source and destination checks)
# ==============================================================================
IT_TEST_FILES=$(find "$CONNECTOR_DIR/src/test" -name "*IT.java" 2>/dev/null)
IT_TEST_FILE=""
IT_TEST_COUNT=0

if [[ -n "$IT_TEST_FILES" ]]; then
    IT_TEST_COUNT=$(echo "$IT_TEST_FILES" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')
    IT_TEST_FILE=$(echo "$IT_TEST_FILES" | grep "ConnectorIT.java" | head -1)
    if [[ -z "$IT_TEST_FILE" ]]; then
        IT_TEST_FILE=$(echo "$IT_TEST_FILES" | head -1)
    fi
fi

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
        HELPER_COMPLETE=$(grep -rl "\.completeProcessing()\|processor\.getResult()\|\.getResult()" "$CONNECTOR_CLASS_DIR"/ --include="*.java" 2>/dev/null | head -1 || true)
        if [[ -n "$HELPER_COMPLETE" ]]; then
            echo "✓ Found .completeProcessing()/.getResult() in helper class"
            echo "   → $(basename "$HELPER_COMPLETE")"
        else
            echo "❌ CRITICAL: Missing .completeProcessing() or .getResult() call"
            echo "   → Must call processor.completeProcessing() or processor.getResult()"
            echo "   → This returns RecordProcessingResult for building response"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    if ! grep -q "SyncStateResponseBuilder" "$CONNECTOR_FILE"; then
        HELPER_SYNC_BUILDER=$(grep -rl "SyncStateResponseBuilder" "$CONNECTOR_CLASS_DIR"/ --include="*.java" 2>/dev/null | head -1 || true)
        if [[ -n "$HELPER_SYNC_BUILDER" ]]; then
            if grep -q "fromProcessingResult" "$HELPER_SYNC_BUILDER"; then
                echo "✓ Found SyncStateResponseBuilder.fromProcessingResult() in helper class"
                echo "   → $(basename "$HELPER_SYNC_BUILDER")"
            else
                echo "⚠️  WARNING: SyncStateResponseBuilder found in helper but not fromProcessingResult()"
                echo "   → $(basename "$HELPER_SYNC_BUILDER")"
                echo "   → Should use: SyncStateResponseBuilder.fromProcessingResult(result, mode)"
                WARNINGS=$((WARNINGS + 1))
            fi
        else
            echo "❌ CRITICAL: Missing SyncStateResponseBuilder usage"
            echo "   → Must use SyncStateResponseBuilder.fromProcessingResult()"
            ERRORS=$((ERRORS + 1))
        fi
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
    if grep -q "DatasourceInitResponse\.builder" "$CONNECTOR_SRC_DIR"/*.java "$CONNECTOR_SRC_DIR"/*/*.java 2>/dev/null; then
        echo "❌ ERROR: Using DatasourceInitResponse.builder()"
        echo "   → WRONG: DatasourceInitResponse has no builder"
        echo "   → CORRECT: new DatasourceInitResponse(); response.setDatasourceProductName(...); response.setDatasourceProductVersion(...)"
        ERRORS=$((ERRORS + 1))
    fi

    if grep -q "\.productName(\|\.productVersion(" "$CONNECTOR_SRC_DIR"/*.java "$CONNECTOR_SRC_DIR"/*/*.java 2>/dev/null; then
        echo "❌ ERROR: Using non-existent DatasourceInitResponse builder-style methods"
        echo "   → WRONG: .productName(), .productVersion()"
        echo "   → CORRECT: setDatasourceProductName(), setDatasourceProductVersion(), setDefaultCatalog(), setDefaultSchema()"
        ERRORS=$((ERRORS + 1))
    fi

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

# Source-only connectors still need interface-required stubs for destination methods.
if $IS_SOURCE_CONNECTOR && ! $IS_DESTINATION_CONNECTOR_EARLY; then
    echo "  Source-only stub method checks:"

    if grep -q "public.*ObjectMetadata mapToTargetObject" "$CONNECTOR_FILE"; then
        if grep -A12 "public.*ObjectMetadata mapToTargetObject" "$CONNECTOR_FILE" | grep -q "UnsupportedOperationException\|UNSUPPORTED_OPERATION\|source-only"; then
            echo "✓ mapToTargetObject() source-only stub present"
        else
            echo "⚠️  WARNING: mapToTargetObject() exists but does not throw an unsupported-operation error"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo "⚠️  WARNING: Missing mapToTargetObject() stub for source-only connector"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -q "public.*StageResponse stage" "$CONNECTOR_FILE"; then
        if grep -A8 "public.*StageResponse stage" "$CONNECTOR_FILE" | grep -q "UnsupportedOperationException\|UNSUPPORTED_OPERATION\|source-only"; then
            echo "✓ stage() source-only stub present"
        else
            echo "⚠️  WARNING: stage() exists but does not throw an unsupported-operation error"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo "⚠️  WARNING: Missing stage() stub for source-only connector"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -q "public.*LoadResponse load" "$CONNECTOR_FILE"; then
        if grep -A8 "public.*LoadResponse load" "$CONNECTOR_FILE" | grep -q "UnsupportedOperationException\|UNSUPPORTED_OPERATION\|source-only"; then
            echo "✓ load() source-only stub present"
        else
            echo "⚠️  WARNING: load() exists but does not throw an unsupported-operation error"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo "⚠️  WARNING: Missing load() stub for source-only connector"
        WARNINGS=$((WARNINGS + 1))
    fi

    echo ""
fi

# ==============================================================================
# CHECK 3.5: ObjectMetadata and FieldMetadata Requirements (for REST connectors)
# ==============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CHECK 3.5: ObjectMetadata and FieldMetadata Requirements"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if this is a JDBC connector (extends BaseJdbcConnector)
if grep -q "extends BaseJdbcConnector" "$CONNECTOR_FILE"; then
    echo "ℹ️  JDBC connector - BaseJdbcConnector handles metadata compliance automatically"
    echo "✓ ObjectMetadata strategies handled by base class"
    echo "✓ FieldMetadata required fields handled by base class"
else
    # REST connector - must set metadata fields manually, often in helper classes.
    if grep -Rq --include="*.java" "setIncrementalSyncSupported[[:space:]]*(" "$CONNECTOR_SRC_DIR"; then
        echo "❌ ERROR: Using non-existent ObjectMetadata.setIncrementalSyncSupported()"
        echo "   → CORRECT: object.setIncrementalStrategy(IncrementalStrategy.COLUMN_CURSOR or UNSUPPORTED)"
        ERRORS=$((ERRORS + 1))
    fi

    if grep -Rq --include="*.java" "setNullable[[:space:]]*(" "$CONNECTOR_SRC_DIR"; then
        echo "❌ ERROR: Using non-existent FieldMetadata.setNullable()"
        echo "   → CORRECT: field.setNillable(...)"
        ERRORS=$((ERRORS + 1))
    fi

    if grep -Rq --include="*.java" "setSourcePath[[:space:]]*(" "$CONNECTOR_SRC_DIR"; then
        echo "❌ ERROR: Using non-existent FieldMetadata.setSourcePath()"
        echo "   → Store source paths in field names or custom attributes when truly needed"
        ERRORS=$((ERRORS + 1))
    fi

    if grep -Rq --include="*.java" "setSourcePrimaryKey[[:space:]]*([[:space:]]*false\|setSourceCursorField[[:space:]]*([[:space:]]*false" "$CONNECTOR_SRC_DIR"; then
        echo "❌ ERROR: Source metadata flags are explicitly set to false"
        echo "   → sourcePrimaryKey/sourceCursorField are sparse booleans: set true or leave null"
        ERRORS=$((ERRORS + 1))
    fi

    if grep -Rq --include="*.java" "new FieldMetadata[[:space:]]*(" "$CONNECTOR_SRC_DIR"; then
        echo "ℹ️  REST connector creates FieldMetadata objects"

        if grep -Rq --include="*.java" "setOriginalDataType" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found setOriginalDataType() calls"
        else
            echo "❌ ERROR: Missing setOriginalDataType() in schema discovery"
            echo "   → FieldMetadata MUST have originalDataType set"
            echo "   → This is the source system's type (e.g., 'string', 'datetime')"
            echo "   → Used by CSV processor, schema evolution, and destination DDL"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -Rq --include="*.java" "setCanonicalType" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found setCanonicalType() calls"
        else
            echo "❌ ERROR: Missing setCanonicalType() in schema discovery"
            echo "   → FieldMetadata MUST have canonicalType set"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -Rq --include="*.java" "setPrimaryKeyCapable" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found setPrimaryKeyCapable() calls"
        else
            echo "❌ ERROR: Missing setPrimaryKeyCapable() in schema discovery"
            echo "   → Metadata compliance requires primaryKeyCapable to be non-null"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -Rq --include="*.java" "setCursorCapable" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found setCursorCapable() calls"
        else
            echo "❌ ERROR: Missing setCursorCapable() in schema discovery"
            echo "   → Metadata compliance requires cursorCapable to be non-null"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -Rq --include="*.java" "CanonicalType\.BIGDECIMAL" "$CONNECTOR_SRC_DIR"; then
            if grep -Rq --include="*.java" "setPrecision" "$CONNECTOR_SRC_DIR" && \
               grep -Rq --include="*.java" "setScale" "$CONNECTOR_SRC_DIR"; then
                echo "✓ BIGDECIMAL fields set precision and scale"
            else
                echo "❌ ERROR: BIGDECIMAL mapping found without precision/scale setters"
                echo "   → BIGDECIMAL requires precision 1..38 and scale 0..min(37, precision)"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    else
        echo "ℹ️  No direct FieldMetadata creation found"
    fi

    if grep -Rq --include="*.java" "new ObjectMetadata[[:space:]]*(" "$CONNECTOR_SRC_DIR"; then
        echo "ℹ️  REST connector creates ObjectMetadata objects"

        if grep -Rq --include="*.java" "setFullyQualifiedName" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found setFullyQualifiedName() calls"
        else
            echo "❌ ERROR: Missing setFullyQualifiedName() in schema discovery"
            echo "   → ObjectMetadata fullyQualifiedName must be non-blank"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -Rq --include="*.java" "setType[[:space:]]*(" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found ObjectMetadata setType() calls"
        else
            echo "❌ ERROR: Missing ObjectMetadata.setType() in schema discovery"
            echo "   → source_metadata_catalog.object_type is NOT NULL; use object.setType(\"TABLE\")"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -Rq --include="*.java" "setFields[[:space:]]*(" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found setFields() calls"
        else
            echo "❌ ERROR: Missing setFields() in schema discovery"
            echo "   → ObjectMetadata must carry discovered FieldMetadata"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -Rq --include="*.java" "setIncrementalStrategy" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found setIncrementalStrategy() calls"
        else
            echo "❌ ERROR: Missing setIncrementalStrategy() in schema discovery"
            echo "   → Use COLUMN_CURSOR, CONNECTOR_MANAGED, or UNSUPPORTED; do not leave null"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -Rq --include="*.java" "IncrementalStrategy\.NONE" "$CONNECTOR_SRC_DIR"; then
            echo "❌ ERROR: Using legacy IncrementalStrategy.NONE"
            echo "   → Use IncrementalStrategy.UNSUPPORTED when incremental sync is unavailable"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -Rq --include="*.java" "setIdentityStrategy" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found setIdentityStrategy() calls"
        else
            echo "❌ ERROR: Missing setIdentityStrategy() in schema discovery"
            echo "   → Use SOURCE_KEY when source keys exist, otherwise ROW_HASH"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -Rq --include="*.java" "setObjectType" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found setObjectType() calls"
        else
            echo "⚠️  WARNING: Missing setObjectType() in schema discovery"
            echo "   → Recommended: object.setObjectType(ObjectType.PRIMARY) for normal source objects"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo "ℹ️  No direct ObjectMetadata creation found"
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
    if ! grep -qE 'connector\.version=|project\.version' "$CONNECTOR_DIR/src/main/resources/version.properties"; then
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

if $HAS_INVALID_READ_CAPABILITY; then
    echo "❌ ERROR: Using ConnectorCapabilities.READ"
    echo "   → WRONG: ConnectorCapabilities.READ (doesn't exist)"
    echo "   → CORRECT: ConnectorCapabilities.REPLICATION_SOURCE"
    ERRORS=$((ERRORS + 1))
fi

if $HAS_INVALID_WRITE_CAPABILITY; then
    echo "❌ ERROR: Using ConnectorCapabilities.WRITE"
    echo "   → WRONG: ConnectorCapabilities.WRITE (doesn't exist)"
    echo "   → CORRECT: ConnectorCapabilities.REPLICATION_DESTINATION"
    ERRORS=$((ERRORS + 1))
fi

if $HAS_INVALID_SCHEMA_DISCOVERY_CAPABILITY; then
    echo "❌ ERROR: Using ConnectorCapabilities.SCHEMA_DISCOVERY"
    echo "   → This capability doesn't exist, remove it"
    ERRORS=$((ERRORS + 1))
fi

if $IS_SOURCE_CONNECTOR || $IS_DESTINATION_CONNECTOR_EARLY; then
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

    # Check for mandatory @Property annotation attributes.
    # The SDK annotation declares label() and description() without defaults, so both are required.
    MISSING_PROPERTY_ATTRS=$(awk '
        /@Property[[:space:]]*\(/ {
            in_property = 1
            start_line = NR
            has_label = 0
            has_description = 0
        }
        in_property && /label[[:space:]]*=/ { has_label = 1 }
        in_property && /description[[:space:]]*=/ { has_description = 1 }
        in_property && /\)/ {
            if (!has_label || !has_description) {
                printf("line %d: missing%s%s\n",
                    start_line,
                    has_label ? "" : " label",
                    has_description ? "" : " description")
            }
            in_property = 0
        }
    ' "$CONNECTOR_FILE")

    if [[ -n "$MISSING_PROPERTY_ATTRS" ]]; then
        echo "❌ ERROR: @Property annotations missing mandatory attributes"
        echo "   → SDK annotation requires label() and description(); neither has a default"
        echo "$MISSING_PROPERTY_ATTRS" | while read -r line; do
            echo "      $line"
        done
        ERRORS=$((ERRORS + 1))
    else
        echo "✓ @Property annotations include required label and description"
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

if $IS_JDBC_CONNECTOR; then
    echo "ℹ️  JDBC cursor discovery and lower-bound fallback are inherited from BaseJdbcConnector"
    if grep -q "useCutoffTimeForTimeBasedCursors" "$CONNECTOR_FILE" \
            && grep -A4 "useCutoffTimeForTimeBasedCursors" "$CONNECTOR_FILE" | grep -q "return true"; then
        echo "✓ JDBC connector opts time-based cursors into cutoff-time windows"
        echo "✓ Cutoff state bypasses result maximums and boundary-count queries"
        run_java_evidence_check \
            "cutoff-state" \
            "IT separately proves empty-initial suppression and empty-incremental advancement"
    else
        echo "⚠️  WARNING: JDBC connector uses the count-at-boundary fallback"
        echo "   → Confirm the source cannot enforce cursor < cutoffTime"
        echo "   → If it can, override useCutoffTimeForTimeBasedCursors() and return true"
        WARNINGS=$((WARNINGS + 1))
    fi
elif grep -q "identifyCursorFields\|setSourceCursorField\|setCursorField\|SyncStateRequest" "$CONNECTOR_FILE"; then
    echo "ℹ️  Incremental sync features detected"

    if grep -q "identifyCursorFields" "$CONNECTOR_FILE"; then
        echo "✓ Found identifyCursorFields() implementation"

        # Check for hardcoded field names
        if grep -q 'setSourceCursorField.*"updated_at"\|setSourceCursorField.*"modified_date"\|setCursorField.*"updated_at"\|setCursorField.*"modified_date"' "$CONNECTOR_FILE"; then
            echo "⚠️  WARNING: Possible hardcoded cursor field name"
            echo "   → Should use priority-based search, not hardcode field names"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    if grep -q "getServerTimeOffset" "$CONNECTOR_FILE"; then
        echo "✓ Found getServerTimeOffset() implementation (cutoff time strategy)"
    fi

    if grep -q "CutoffTimeSyncUtils\|getCutoffTime" "$CONNECTOR_FILE"; then
        run_java_evidence_check \
            "cutoff-state" \
            "IT separately proves empty-initial suppression and empty-incremental advancement"
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

if grep -Rq --include="*.java" "OAuthConfig\|oauthConfig\|accessToken\|refreshToken" "$CONNECTOR_SRC_DIR"; then
    echo "ℹ️  OAuth features detected"

    if grep -Rq --include="*.java" "OAuthConfig\.Builder" "$CONNECTOR_SRC_DIR"; then
        echo "✓ Found OAuthConfig.Builder implementation"

        if grep -Rq --include="*.java" "withScopes" "$CONNECTOR_SRC_DIR"; then
            echo "✓ Found scope configuration"
            echo "   ℹ️  Verify all required scopes are included"
        else
            echo "⚠️  WARNING: OAuthConfig found but no scopes configured"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    # Check for token refresh patterns across connector helpers such as auth/*OAuthManager.
    if grep -Rqi --include="*.java" "refreshToken\|tokenRefresh\|refresh.*token\|token.*refresh\|expired.*refresh\|refreshing" "$CONNECTOR_SRC_DIR"; then
        echo "✓ Found token refresh logic"
    else
        echo "⚠️  WARNING: OAuth tokens found but no refresh logic"
        echo "   → Should handle token expiry and refresh"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -Rq --include="*.java" "isTokenExpired\|tokenExpiresAt" "$CONNECTOR_SRC_DIR"; then
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

# Extract getType() return value, including constants in helper classes.
CONNECTOR_TYPE=$(resolve_java_string_return "getType")

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

# Extract getName() return value, including constants in helper classes.
CONNECTOR_DISPLAY_NAME=$(resolve_java_string_return "getName")

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

# Security default check for TLS certificate trust behavior
if grep -q "trustServerCertificate" "$CONNECTOR_FILE"; then
    if grep -A10 -B6 "trustServerCertificate" "$CONNECTOR_FILE" | grep -q 'defaultValue[[:space:]]*=[[:space:]]*"true"'; then
        echo "⚠️  WARNING: trustServerCertificate defaults to true"
        echo "   → Recommended default is false for production safety"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# Check icon lookup
echo ""
echo "  Icon Check:"

# Derive expected icon filename from connector name
if [[ -n "$CONNECTOR_DISPLAY_NAME" ]]; then
    ICON_FOUND=""
    ICON_NAME_DISPLAY=$(echo "$CONNECTOR_DISPLAY_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//; s/_$//')
    ICON_NAME_DISPLAY_SIMPLE=$(echo "$CONNECTOR_DISPLAY_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    ICON_PATH_ARTIFACT="../supaflow-www/public/connectors/${CONNECTOR_NAME}.svg"
    ICON_PATH_DISPLAY="../supaflow-www/public/connectors/${ICON_NAME_DISPLAY}.svg"
    ICON_PATH_DISPLAY_SIMPLE="../supaflow-www/public/connectors/${ICON_NAME_DISPLAY_SIMPLE}.svg"

    if find "$CONNECTOR_DIR/src/main/resources" -name "*.svg" -print -quit 2>/dev/null | grep -q .; then
        echo "✓ Found bundled SVG icon in connector resources"
        ICON_FOUND="yes"
    elif grep -rq "<svg\|getResourceAsStream\|Base64\|ICON" "$CONNECTOR_SRC_DIR" --include="*.java" 2>/dev/null; then
        echo "✓ Found getIcon() bundled/embedded icon implementation"
        ICON_FOUND="yes"
    fi

    if [ -f "$ICON_PATH_ARTIFACT" ]; then
        echo "✓ Found icon: connectors/${CONNECTOR_NAME}.svg"
        ICON_FOUND="yes"
    elif [ -f "$ICON_PATH_DISPLAY" ]; then
        echo "✓ Found icon: connectors/${ICON_NAME_DISPLAY}.svg"
        ICON_FOUND="yes"
    elif [ -f "$ICON_PATH_DISPLAY_SIMPLE" ]; then
        echo "✓ Found icon: connectors/${ICON_NAME_DISPLAY_SIMPLE}.svg"
        ICON_FOUND="yes"
    fi

    if grep -rq "getIcon" "$CONNECTOR_SRC_DIR" --include="*.java" 2>/dev/null; then
        if grep -R -A5 "getIcon" "$CONNECTOR_SRC_DIR" --include="*.java" 2>/dev/null | grep -q 'return[[:space:]]*""'; then
            echo "❌ ERROR: getIcon() returns an empty icon"
            echo "   → Connector deployment/UI expects a real icon"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "⚠️  WARNING: Missing getIcon() implementation"
        WARNINGS=$((WARNINGS + 1))
    fi

    if [ -z "$ICON_FOUND" ]; then
        echo "⚠️  WARNING: No icon found at expected locations:"
        echo "   → Checked: connectors/${CONNECTOR_NAME}.svg"
        echo "   → Checked: connectors/${ICON_NAME_DISPLAY}.svg"
        echo "   → Checked: connectors/${ICON_NAME_DISPLAY_SIMPLE}.svg"
        echo "   → Checked: connector resources and embedded getIcon() implementation"
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
    # REST connector - check for source-discovered primary key identification.
    echo "ℹ️  REST connector - checking source PK/cursor identification"

    # Source discovery should set sourcePrimaryKey. The effective primaryKey
    # flag is owned by the metadata merge layer after user selection.
    if grep -q "\.setSourcePrimaryKey(" "$CONNECTOR_FILE"; then
        echo "✓ Found setSourcePrimaryKey() call"
    else
        HELPER_SOURCE_PK=$(grep -rl "\.setSourcePrimaryKey(" "$CONNECTOR_SRC_DIR" 2>/dev/null | head -1 || true)
        if [[ -n "$HELPER_SOURCE_PK" ]]; then
            echo "✓ Found setSourcePrimaryKey() in helper class"
            echo "   → $(basename "$HELPER_SOURCE_PK")"
        else
            echo "⚠️  WARNING: No setSourcePrimaryKey() found"
            echo "   → Source connectors should identify source primary key defaults"
            echo "   → Required for merge operations and deduplication"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    if grep -rq "\.setPrimaryKey(" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
        echo "⚠️  WARNING: Found setPrimaryKey() in source connector code"
        echo "   → Source schema discovery should usually set setSourcePrimaryKey() only"
        echo "   → primaryKey is the effective user/runtime selection populated by metadata merge"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Check for cursor field identification - supports three patterns:
    # Pattern 1: identifyCursorFields() method with proper implementation
    # Pattern 2: Inline source cursor setting during schema building
    # Pattern 3: Utility class delegation (SomeUtil.identifyCursorFields())
    CURSOR_METHOD=$(grep -A20 'public void identifyCursorFields' "$CONNECTOR_FILE" 2>/dev/null || true)
    HAS_INLINE_CURSOR=$(grep -q "setSourceCursorField(true)" "$CONNECTOR_FILE" && echo "yes" || echo "no")
    # Check for utility class delegation (e.g., SalesforceMetadataUtil.identifyCursorFields)
    HAS_UTIL_DELEGATION=$(echo "$CURSOR_METHOD" | grep -q '[A-Z][a-zA-Z]*Util\.\|[A-Z][a-zA-Z]*Helper\.' && echo "yes" || echo "no")

    if [[ -n "$CURSOR_METHOD" ]]; then
        # Has identifyCursorFields() method - check implementation
        if echo "$CURSOR_METHOD" | grep -q 'setSourceCursorField\|setCursorField'; then
            echo "✓ identifyCursorFields() has proper implementation"

            if echo "$CURSOR_METHOD" | grep -q 'setSourceCursorField(true)'; then
                echo "✓ Sets setSourceCursorField(true)"
            elif echo "$CURSOR_METHOD" | grep -q 'setCursorField(true)'; then
                echo "⚠️  WARNING: Uses legacy setCursorField(true) without setSourceCursorField(true)"
                echo "   → Source discovery should set sourceCursorField; cursorField is effective runtime selection"
                WARNINGS=$((WARNINGS + 1))
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
                echo "✓ Uses INLINE source cursor field setting pattern"
                echo "   → setSourceCursorField() called directly during schema building"
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
        echo "✓ Uses INLINE source cursor field setting pattern"
        echo "   → setSourceCursorField() called directly during schema building"

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
        echo "   → No identifyCursorFields() method and no inline setSourceCursorField()"
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
    # 3. Inline: setSourceCursorField(true) directly during schema building

    HAS_CURSOR_METHOD=$(grep -q "identifyCursorFields(" "$CONNECTOR_FILE" && echo "yes" || echo "no")
    HAS_INLINE_CURSOR=$(grep -rq "setSourceCursorField(true)" "$CONNECTOR_CLASS_DIR"/ --include="*.java" 2>/dev/null && echo "yes" || echo "no")

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
            echo "   → setSourceCursorField() called directly during schema building"
        else
            echo "❌ ERROR: identifyCursorFields() method EXISTS but is NEVER CALLED"
            echo "   → The method is defined but not invoked in schema()"
            echo "   → Incremental sync will be dead code - no cursor fields marked"
            echo "   → Fix by EITHER:"
            echo "     1. Add: identifyCursorFields(objectMetadata) in buildObjectMetadata()"
            echo "     2. Or set source cursor fields inline during field building"
            ERRORS=$((ERRORS + 1))
        fi
    elif [[ "$HAS_INLINE_CURSOR" == "yes" ]]; then
        # No identifyCursorFields() but has inline cursor setting
        echo "✓ Uses INLINE cursor field setting pattern"
        echo "   → setSourceCursorField() called directly during schema building"
    else
        echo "⚠️  WARNING: No cursor field identification found"
        echo "   → No identifyCursorFields() and no inline setSourceCursorField()"
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

# IT_TEST_FILE/IT_TEST_FILES already set earlier
if [[ -n "$IT_TEST_FILE" ]]; then
    echo "✓ Found IT test file(s): $IT_TEST_COUNT"
    echo "   Primary file: $(basename "$IT_TEST_FILE")"

    # Ordered/shared-instance annotations are optional for self-contained ITs.
    if grep -R -q --include="*IT.java" "@TestInstance.*PER_CLASS" "$CONNECTOR_DIR/src/test"; then
        echo "✓ Has @TestInstance(PER_CLASS) annotation"
    else
        echo "ℹ️  No shared JUnit test instance (valid for self-contained ITs)"
    fi

    if grep -R -q --include="*IT.java" "@TestMethodOrder" "$CONNECTOR_DIR/src/test"; then
        echo "✓ Has @TestMethodOrder annotation"
    else
        echo "ℹ️  No ordered JUnit execution (valid for self-contained ITs)"
    fi

    # Check behavior rather than requiring test-name prefixes.
    if grep -R -q --include="*IT.java" "\.init[[:space:]]*(" "$CONNECTOR_DIR/src/test"; then
        echo "✓ Has initialization test"
    else
        echo "⚠️  WARNING: Missing live connector.init(...) coverage"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -R -q --include="*IT.java" "\.schema[[:space:]]*(" "$CONNECTOR_DIR/src/test"; then
        echo "✓ Has schema discovery test"
    else
        echo "⚠️  WARNING: Missing live connector.schema(...) coverage"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -R -q --include="*IT.java" "\.read[[:space:]]*(" "$CONNECTOR_DIR/src/test"; then
        echo "✓ Has read data test"
    else
        echo "⚠️  WARNING: Missing live connector.read(...) coverage"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -R -q --include="*IT.java" \
            "initialSync(false)\|cursorPosition\|assertCutoffState" \
            "$CONNECTOR_DIR/src/test"; then
        echo "✓ Has cursor tracking test"
    else
        echo "⚠️  WARNING: Missing behavioral incremental cursor coverage"
        WARNINGS=$((WARNINGS + 1))
    fi

    # IT tests should also model processor lifecycle correctly.
    if grep -R --include="*IT.java" -h "processor\.close()" "$CONNECTOR_DIR/src/test" \
        | grep -v '^[[:space:]]*//' | grep -v '^[[:space:]]*\*' >/dev/null; then
        echo "⚠️  WARNING: IT test manually calls processor.close()"
        echo "   → Tests should model runtime behavior where executor owns processor lifecycle"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "✓ IT test does not call processor.close()"
    fi
else
    echo "❌ ERROR: No integration test file found (*IT.java)"
    echo "   → Create IT tests following CONNECTOR_TESTING_SKILL.md"
    echo "   → IT tests validate the full connector lifecycle"
    ERRORS=$((ERRORS + 1))
fi

echo ""

fi # End of source checks conditional block

# ==============================================================================
# JDBC CONNECTOR CHECKS (auto-detected)
# Only run if connector extends BaseJdbcConnector
# ==============================================================================

if $IS_JDBC_CONNECTOR; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✓ JDBC CONNECTOR CHECKS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "ℹ️  Detected BaseJdbcConnector subclass"
    echo ""

    if ! $IS_SOURCE_CONNECTOR; then
        echo "ℹ️  Skipping source-side canonical conversion check for destination-only JDBC connector"
    elif grep -rq "convertToCanonicalValue" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
        echo "✓ Has convertToCanonicalValue override (handles driver-specific types)"
    else
        echo "⚠️  WARNING: Missing convertToCanonicalValue override"
        echo "   → JDBC drivers return proprietary Java types (e.g., microsoft.sql.DateTimeOffset)"
        echo "   → Without this override, these types cause ClassCastException at runtime"
        echo "   → See JDBC_CONNECTOR_GUIDE.md for implementation pattern"
        WARNINGS=$((WARNINGS + 1))
    fi

    if grep -rq "mapTypeByName" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
        echo "✓ Has mapTypeByName override (maps database-specific type names)"
    else
        echo "⚠️  WARNING: Missing mapTypeByName override"
        echo "   → Database-specific types may not map correctly via JDBC type constants alone"
        echo "   → See JDBC_CONNECTOR_GUIDE.md for implementation pattern"
        WARNINGS=$((WARNINGS + 1))
    fi

    echo ""
fi

# ==============================================================================
# DESTINATION CONNECTOR CHECKS (16-25)
# Only run if connector declares REPLICATION_DESTINATION capability
# Skip for source-only connectors unless they also have destination capability
# ==============================================================================

# Use the early-detected destination flag
IS_DESTINATION_CONNECTOR=$IS_DESTINATION_CONNECTOR_EARLY

if ! $IS_DESTINATION_CONNECTOR && $IS_SOURCE_CONNECTOR; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⏭  SKIPPING DESTINATION CHECKS"
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

    # Report the type derived from active capabilities/configuration method bodies.
    if $IS_ACTIVATION_DESTINATION; then
        echo "ℹ️  Destination Type: ACTIVATION (API-based, no staging)"
    elif $IS_DIRECT_DATABASE_DESTINATION; then
        echo "ℹ️  Destination Type: DIRECT DATABASE (no external staging, explicit load)"
    elif $IS_WAREHOUSE_DESTINATION; then
        echo "ℹ️  Destination Type: STAGED WAREHOUSE/FILE (staging + load)"
    else
        echo "⚠️  WARNING: Destination type could not be determined from capabilities config"
        WARNINGS=$((WARNINGS + 1))
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
                echo "⚠️  WARNING: Staged warehouse/file destination should define staging config"
                WARNINGS=$((WARNINGS + 1))
            fi
        elif $IS_DIRECT_DATABASE_DESTINATION; then
            if grep -q "requiresStaging(false)" "$CONNECTOR_FILE"; then
                echo "✓ Direct database destination declares requiresStaging(false)"
            else
                echo "⚠️  WARNING: Direct database destination should declare requiresStaging(false)"
                WARNINGS=$((WARNINGS + 1))
            fi
            if grep -q "requiresExplicitLoadStep(true)" "$CONNECTOR_FILE"; then
                echo "✓ Direct database destination declares explicit load step"
            else
                echo "⚠️  WARNING: Direct database destination should declare requiresExplicitLoadStep(true)"
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
        MAP_TO_TARGET_METHOD=$(grep -A 180 "public.*ObjectMetadata mapToTargetObject" "$CONNECTOR_FILE" 2>/dev/null || true)

        # Structured destinations must apply NamespaceRules. Activation destinations pass
        # through activation metadata and resolve target objects/fields during load().
        if $IS_ACTIVATION_DESTINATION; then
            echo "ℹ️  Activation destination may use pass-through mapToTargetObject()"
        elif grep -rq "namespaceRules\.get\|namespaceRules\.apply\|getTableName\|getSchemaName\|getDatabaseName" "$CONNECTOR_SRC_DIR" --include="*.java" 2>/dev/null; then
            echo "✓ Applies NamespaceRules (pipeline prefix)"
        else
            echo "❌ ERROR: mapToTargetObject() does not apply NamespaceRules"
            echo "   → Must call namespaceRules.getTableName/getSchemaName/getDatabaseName"
            echo "   → Pipeline prefix will not be applied"
            ERRORS=$((ERRORS + 1))
        fi

        # Check that tracking columns are NOT added
        if echo "$MAP_TO_TARGET_METHOD" | grep -q "setName *( *[\"']_supa_\|addField *(.*_supa_\|FieldMetadata.*_supa_"; then
            echo "❌ ERROR: mapToTargetObject() adds tracking columns"
            echo "   → DO NOT add _supa_* columns in mapToTargetObject()"
            echo "   → Writer/schema mapper adds them automatically"
            echo "   → Adding them here causes duplicates"
            ERRORS=$((ERRORS + 1))
        else
            echo "✓ Does not add tracking columns (correct)"
        fi

        # Check customAttributes preservation
        if echo "$MAP_TO_TARGET_METHOD" | grep -q "setCustomAttributes\|customAttributes"; then
            echo "✓ Preserves customAttributes (sync metadata)"
        else
            echo "⚠️  WARNING: May not preserve customAttributes"
            echo "   → Should copy sourceObj.getCustomAttributes() to destination"
            echo "   → Contains supa_sync_time and other metadata"
            WARNINGS=$((WARNINGS + 1))
        fi

        if $IS_WAREHOUSE_DESTINATION || $IS_DIRECT_DATABASE_DESTINATION; then
            # Structured destinations: Check NamespaceRules usage
            if grep -q "NamespaceRules\|namespaceRules" "$CONNECTOR_FILE"; then
                echo "✓ Uses NamespaceRules for schema mapping"
            else
                echo "⚠️  WARNING: Structured destination should use NamespaceRules"
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
            # Staged warehouse/file-specific checks
            if grep -q "getStageLocation\|stageLocation" "$LOAD_METHOD"; then
                echo "✓ Handles stageLocation"
            fi

            if grep -q "getLoadMode\|LoadMode" "$LOAD_METHOD"; then
                echo "✓ Handles LoadMode"
            else
                echo "⚠️  WARNING: Staged warehouse/file destination should handle LoadMode"
                WARNINGS=$((WARNINGS + 1))
            fi
        elif $IS_DIRECT_DATABASE_DESTINATION; then
            if grep -q "getLocalDataPath\|localDataPath" "$LOAD_METHOD"; then
                echo "✓ Uses localDataPath for direct database loading"
            else
                echo "⚠️  WARNING: Direct database destination should use localDataPath"
                WARNINGS=$((WARNINGS + 1))
            fi

            if grep -q "getLoadMode\|LoadMode" "$LOAD_METHOD"; then
                echo "✓ Handles LoadMode"
            else
                echo "⚠️  WARNING: Direct database destination should handle LoadMode"
                WARNINGS=$((WARNINGS + 1))
            fi

            if grep -q "getSyncTime\|getJobDetailsId" "$LOAD_METHOD"; then
                echo "✓ Uses request sync metadata"
            else
                echo "⚠️  WARNING: Direct database destination should use request.getSyncTime() and request.getJobDetailsId()"
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
    # CHECK 19: stage() Implementation or No-Op
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
            if grep -rq "success_part_\|listSuccessParts\|StagedFiles" "$CONNECTOR_SRC_DIR" --include="*.java" 2>/dev/null; then
                echo "✓ Uses production staged success-part discovery"
            else
                echo "⚠️  WARNING: stage() may not use correct CSV file pattern"
                echo "   → Platform writes success_part_* data files (CSV/JSONL depending on format)"
                echo "   → Should use StagedFiles or filter for success_part_*"
                WARNINGS=$((WARNINGS + 1))
            fi

            # Check that it doesn't look for wrong patterns
            if grep -R -A30 "public.*StageResponse stage" "$CONNECTOR_SRC_DIR" --include="*.java" 2>/dev/null | grep -q "tableName.*_\|tableName + \"_\""; then
                echo "⚠️  WARNING: stage() may be using wrong file pattern (<table>_*.csv)"
                echo "   → This will find zero files in production"
                WARNINGS=$((WARNINGS + 1))
            fi
        elif $IS_DIRECT_DATABASE_DESTINATION; then
            if grep -A10 "public.*StageResponse stage" "$STAGE_FILE" | grep -q "StageResponse.noOp"; then
                echo "✓ stage() returns StageResponse.noOp for direct database load"
            else
                echo "⚠️  WARNING: Direct database destination should return StageResponse.noOp in stage()"
                WARNINGS=$((WARNINGS + 1))
            fi

            if grep -A10 "public.*StageResponse stage" "$STAGE_FILE" | grep -q "StageResponse.success"; then
                echo "⚠️  WARNING: Direct database stage() should not return StageResponse.success with a fake stage location"
                WARNINGS=$((WARNINGS + 1))
            fi
        else
            # Activation should throw or return no-op
            if grep -A10 "public.*StageResponse stage" "$STAGE_FILE" | grep -q "UnsupportedOperationException\|UNSUPPORTED_OPERATION\|throw new\|not supported\|StageResponse.noOp"; then
                echo "✓ stage() correctly throws unsupported-operation error or returns no-op"
            else
                echo "⚠️  WARNING: Activation destination should throw an unsupported-operation error or return StageResponse.noOp in stage()"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        if $IS_WAREHOUSE_DESTINATION; then
            echo "⚠️  WARNING: Staged warehouse/file destination missing stage() method"
            WARNINGS=$((WARNINGS + 1))
        elif $IS_DIRECT_DATABASE_DESTINATION; then
            echo "⚠️  WARNING: Direct database destination missing stage() no-op method"
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
    # DIRECT DATABASE-SPECIFIC CHECKS (20-23)
    # ==============================================================================
    if $IS_DIRECT_DATABASE_DESTINATION; then
        # CHECK 20: Local CSV / bulk load
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 20: Direct Database Load Implementation"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if grep -rq "getLocalDataPath\|localDataPath" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Reads localDataPath"
        else
            echo "⚠️  WARNING: Direct database destination should read LoadRequest.getLocalDataPath()"
            WARNINGS=$((WARNINGS + 1))
        fi

        if grep -rq "success_part_\|discoverCsvFiles\|copyFromCsv\|BULK INSERT\|BulkCopy" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Found local CSV/bulk load implementation"
        else
            echo "⚠️  WARNING: No local CSV/bulk load implementation found"
            WARNINGS=$((WARNINGS + 1))
        fi

        if grep -rq "getSyncTime\|getJobDetailsId" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Uses request sync metadata for tracking"
        else
            echo "⚠️  WARNING: Direct database destination should use request.getSyncTime() and request.getJobDetailsId()"
            WARNINGS=$((WARNINGS + 1))
        fi

        echo ""

        # CHECK 21: MERGE implementation
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 21: MERGE Implementation"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if grep -rq "MERGE INTO\|executeMerge\|buildMergeSql\|ON CONFLICT\|UPSERT" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Found MERGE/upsert implementation"
        else
            echo "⚠️  WARNING: No MERGE/upsert implementation found"
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
    # STAGED WAREHOUSE/FILE-SPECIFIC CHECKS (20-23)
    # ==============================================================================
    if $IS_WAREHOUSE_DESTINATION; then
        # CHECK 20: COPY INTO / Staging load
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 20: Staging Load Implementation"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if grep -rq "COPY INTO\|executeCopyInto\|copyInto\|JobConfiguration\.Load" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Found COPY INTO implementation"
        else
            if grep -rq "uploadToStage\|PUT.*stage\|stageLocation\|GcsStager\|S3Stager\|storage\.create\|writeChannel" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
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

        if grep -rq "MERGE INTO\|executeMerge\|buildMergeSql\|mergeSql\|append(\"MERGE" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
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

        if grep -rq "CREATE TABLE\|createTable\|buildCreateTableSql\|create(TableInfo\|create(DatasetInfo" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
            echo "✓ Found CREATE TABLE implementation"
        else
            echo "⚠️  WARNING: No CREATE TABLE implementation found"
            WARNINGS=$((WARNINGS + 1))
        fi

        if grep -rq "ALTER TABLE\|alterTable\|buildAlterTableSql\|update(table\.toBuilder\|bigQuery\.update" "$CONNECTOR_SRC_DIR" 2>/dev/null; then
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
        echo "✓ Found IT test file(s): $IT_TEST_COUNT"
        # Check for destination-specific tests
        if grep -R -q --include="*IT.java" "testLoad\|testWrite\|testUpsert\|LoadMode\|loadRows\|\\.load(" "$CONNECTOR_DIR/src/test" 2>/dev/null; then
            echo "✓ Has load/write test"
        else
            echo "⚠️  WARNING: Missing load/write test in IT"
            WARNINGS=$((WARNINGS + 1))
        fi

        # CRITICAL: Check for realistic test data (not simplified)
        if grep -R -q --include="*IT.java" --include="*Test.java" \
                "success_part_\|StagedFiles\.SUCCESS_PART_PREFIX" \
                "$CONNECTOR_DIR/src/test"; then
            echo "✓ Test coverage uses realistic success_part_* file patterns"
        else
            echo "⚠️  WARNING: IT tests may use simplified CSV file names"
            echo "   → Should use production patterns: success_part_*.csv or success_part_*.jsonl"
            echo "   → Simplified names don't catch stage file discovery issues"
            WARNINGS=$((WARNINGS + 1))
        fi

        # Check for namespace-rules validation. Unit tests are acceptable here because
        # mapToTargetObject() is deterministic and does not require live credentials.
        if grep -R -q --include="*Test.java" --include="*IT.java" "NamespaceRules\|NamespaceRulesEnum\|pipelinePrefix\|pipeline_prefix\|namespace.*prefix" "$CONNECTOR_DIR/src/test" 2>/dev/null; then
            echo "✓ Tests namespace rules application"
        else
            echo "⚠️  WARNING: Tests may not verify namespace rules"
            echo "   → Should test that mapToTargetObject() applies namespace rules"
            WARNINGS=$((WARNINGS + 1))
        fi

        if $IS_WAREHOUSE_DESTINATION; then
            if grep -R -q --include="*IT.java" "testStage\|testCopyInto\|testMerge\|LoadMode.MERGE\|stageLocation" "$CONNECTOR_DIR/src/test" 2>/dev/null; then
                echo "✓ Has staging/merge test"
            else
                echo "⚠️  WARNING: Missing staging/merge test for staged destination"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi

        if $IS_DIRECT_DATABASE_DESTINATION; then
            if grep -R -q --include="*IT.java" "testLoad\|testMerge\|testAppend\|testOverwrite\|testSqlScript" "$CONNECTOR_DIR/src/test" 2>/dev/null; then
                echo "✓ Has direct database load/merge test"
            else
                echo "⚠️  WARNING: Missing direct database load/merge test"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi

        if $IS_ACTIVATION_DESTINATION; then
            if grep -R -q --include="*IT.java" "testActivation\|testUpsert\|testApiWrite" "$CONNECTOR_DIR/src/test" 2>/dev/null; then
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

    # ==============================================================================
    # CHECK 24.5: Warehouse Destination Maturity Gates
    # ==============================================================================
    if $IS_WAREHOUSE_DESTINATION; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✓ CHECK 24.5: Warehouse Destination Maturity Gates"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if [[ -n "$IT_TEST_FILES" ]]; then
            DEST_MISSING_MODES=()
            for mode in APPEND MERGE OVERWRITE TRUNCATE_AND_LOAD; do
                if grep -R -q --include="*IT.java" "LoadMode\.${mode}" "$CONNECTOR_DIR/src/test" 2>/dev/null; then
                    echo "✓ IT covers LoadMode.${mode}"
                else
                    DEST_MISSING_MODES+=("$mode")
                fi
            done
            if [ ${#DEST_MISSING_MODES[@]} -gt 0 ]; then
                echo "❌ ERROR: Destination IT missing load mode coverage: ${DEST_MISSING_MODES[*]}"
                echo "   → Warehouse destinations must prove APPEND, MERGE, OVERWRITE, and TRUNCATE_AND_LOAD"
                ERRORS=$((ERRORS + 1))
            fi

            DEST_MISSING_TABLE_HANDLINGS=()
            for handling in FAIL DROP MERGE; do
                if grep -R -q --include="*IT.java" "DestinationTableHandling\.${handling}" "$CONNECTOR_DIR/src/test" 2>/dev/null; then
                    echo "✓ IT covers DestinationTableHandling.${handling}"
                else
                    DEST_MISSING_TABLE_HANDLINGS+=("$handling")
                fi
            done
            if [ ${#DEST_MISSING_TABLE_HANDLINGS[@]} -gt 0 ]; then
                echo "⚠️  WARNING: Destination IT missing table-handling coverage: ${DEST_MISSING_TABLE_HANDLINGS[*]}"
                echo "   → First-run behavior should prove FAIL, DROP, and MERGE where supported"
                WARNINGS=$((WARNINGS + 1))
            fi

            run_java_evidence_check \
                "warehouse" \
                "Behavioral warehouse evidence covers types, system fields, callbacks, error artifacts, schema evolution, merge/delete semantics, physical design, concurrent cold starts, JSON readback, and external-stage safety"

        else
            echo "⚠️  WARNING: No IT tests found, skipping warehouse maturity matrix"
            WARNINGS=$((WARNINGS + 1))
        fi

        if grep -rq "copyQueryId\|queryId\|stageLocation\|statement.*failed\|failed.*statement\|statementIndex" "$CONNECTOR_SRC_DIR" --include="*.java" 2>/dev/null; then
            echo "✓ Operational logs include stage/query/statement context"
        else
            echo "⚠️  WARNING: Missing operational log context for staging/COPY/statement failures"
            echo "   → Full source-to-destination smoke tests need query id, stage location, statement index, and row counts"
            WARNINGS=$((WARNINGS + 1))
        fi

        if $IS_JDBC_CONNECTOR; then
            if grep -rq "isRetryableException\|isRetryable\|isRetriable" "$CONNECTOR_SRC_DIR" --include="*.java" 2>/dev/null; then
                echo "✓ Destination has connector-specific retry classification"
                if grep -R -q --include="*Test.java" --include="*IT.java" "isRetryableException\|isRetryable\|isRetriable\|retryable\|retriable\|not retryable\|not retriable\|Query reached usage limit\|timeout\|cancel" "$CONNECTOR_DIR/src/test" 2>/dev/null; then
                    echo "✓ Retry classifier has test coverage"
                else
                    echo "⚠️  WARNING: Retry classifier override lacks test coverage"
                    WARNINGS=$((WARNINGS + 1))
                fi
            else
                echo "⚠️  WARNING: JDBC destination does not override retry classification"
                echo "   → Review broad base JDBC retry SQLState classes and exclude terminal warehouse errors"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi

        echo ""
    fi

    # ==============================================================================
    # CHECK 24.6: Local Agent Deployment Packaging
    # ==============================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✓ CHECK 24.6: Local Agent Deployment Packaging"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ -f "$CONNECTOR_DIR/pom.xml" ]; then
        if grep -q "deploy-local-connector" "$CONNECTOR_DIR/pom.xml" && grep -q "exec-maven-plugin" "$CONNECTOR_DIR/pom.xml"; then
            echo "✓ POM deploys built connector to local agent path"
        else
            echo "❌ ERROR: POM missing deploy-local-connector exec-maven-plugin execution"
            echo "   → Local mvn install can build the JAR but leave the agent without the connector"
            echo "   → Compare with Snowflake/Postgres connector POM deploy-local-connector execution"
            ERRORS=$((ERRORS + 1))
        fi

        if grep -q "<scope>provided</scope>" "$CONNECTOR_DIR/pom.xml"; then
            if grep -q "copy-provided-dependencies\|copy-.*driver" "$CONNECTOR_DIR/pom.xml"; then
                echo "✓ Provided runtime dependencies are copied for local deployment"
            else
                echo "⚠️  WARNING: POM has provided dependencies but no copy-provided-dependencies execution"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
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
            if BUILD_OUTPUT=$(mvn -pl "connectors/supaflow-connector-${CONNECTOR_NAME}" -am -q clean compile 2>&1); then
                echo "✓ Reactor build includes connector (verified)"
            else
                echo "⚠️  WARNING: Reactor build may have issues"
                echo "  → Try: mvn -pl connectors/supaflow-connector-${CONNECTOR_NAME} -am clean compile"
                if [[ -n "$BUILD_OUTPUT" ]]; then
                    echo "$BUILD_OUTPUT" | tail -20
                fi
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
        echo "   mvn -pl connectors/supaflow-connector-${CONNECTOR_NAME} -am clean compile"
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
