from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "skills"
    / "build-supaflow-connector"
    / "scripts"
    / "verify_java_contract_evidence.py"
)
SPEC = importlib.util.spec_from_file_location("verify_java_contract_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


CANONICAL_TYPES = (
    "JSON, STRING, DOUBLE, FLOAT, BIGDECIMAL, LONG, INT, SHORT, BOOLEAN, "
    "INSTANT, LOCALDATETIME, LOCALDATE, BINARY, XML"
)
CANONICAL_REFERENCES = "\n".join(
    f"CanonicalType.{name};" for name in CANONICAL_TYPES.replace(",", "").split()
)

GOOD_CONNECTOR = """
class DemoConnector extends BaseJdbcConnector {
    CanonicalType.JSON;
    protected boolean useCutoffTimeForTimeBasedCursors() { return true; }
    protected String renderSelectItem(FieldMetadata field) {
        if ("STRUCT".equals(field.getOriginalDataType())) {
            return "TO_JSON_STRING(payload) AS payload";
        }
        if ("TIME".equals(field.getOriginalDataType())) {
            return "CAST(event_time AS STRING) AS event_time";
        }
        return field.getName();
    }
    public boolean supportsBatchedSchemaFetch() { return true; }
    List<ObjectMetadata> getObjectAndFieldListBulkOnlyForTest() { return List.of(); }
    public Set<ConnectorCapabilities> getConnectorCapabilities() {
        return Set.of(
            ConnectorCapabilities.REPLICATION_SOURCE,
            ConnectorCapabilities.REPLICATION_DESTINATION);
    }
    public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
        return builder()
            .asCloudWarehouse()
            .requiresStaging(true)
            .supportsHardDeletes(true)
            .build();
    }
}
"""

GOOD_SOURCE_IT = """
class DemoSourceConnectorIT {
    @Test
    void emptyInitialReadDoesNotAdvanceCursor() {
        initialSync(true);
        cutoffTime(INITIAL_CUTOFF);
        assertThat(rows).isEmpty();
        assertThat(response.getSyncState().getEndCursorPosition()).isNull();
    }

    @Test
    void emptyIncrementalReadAdvancesToCutoff() {
        initialSync(false);
        cutoffTime(EMPTY_WINDOW_CUTOFF);
        assertThat(rows).isEmpty();
        assertCutoffState(response, EMPTY_WINDOW_CUTOFF);
    }

    private void assertCutoffState(Object response, Object expectedCutoff) {
        assertThat(response.getSyncState().getEndCursorPosition()).isNotNull();
        assertThat(cursor.getValue()).isEqualTo(expectedCutoff);
        assertThat(cursor.getRecordCount()).isNull();
    }

    @Test
    void readsNamedNestedStructAndExactTimeMicroseconds() {
        JsonNode nested = JSON.readTree(row.get("profile"));
        assertThat(nested.get("name").asText()).isEqualTo("alice");
        assertThat(row.get("event_time")).isEqualTo("12:34:56.123456");
        assertThat(sourceType).isEqualTo("STRUCT");
    }
}
"""

GOOD_ALL_TYPES_IT = (
    """
class DemoAllTypesIT {
    void canonicalTypes() {
"""
    + CANONICAL_REFERENCES
    + """
        BigDecimal decimal = new BigDecimal("123.456");
        nullRecord();
        assertThat(nullValue).isEqualTo("\\\\N");
        assertThat(field.getPrecision()).isEqualTo(76);
        assertThat(field.getScale()).isEqualTo(38);
        assertThat("2026-07-18T12:34:56.123456Z").isNotEmpty();
        assertThat(JSON.readTree(json)).isEqualTo(JSON.readTree(expectedJson));
        assertThat(Base64.getEncoder().encode(binary)).isEqualTo(expectedBytes);
        assertPhysicalTypes(table);
        connector.read(ReadRequest.builder().build());
    }
}
"""
)

GOOD_DESTINATION_IT = """
class DemoDestinationIT {
    @Test
    void exactSystemFieldsAndLiveMerge() {
        assertSystemFieldSchema(table.getSchema());
        query("_supa_synced = TIMESTAMP(syncTime)");
        query("_supa_deleted = FALSE");
        query("_supa_index = 1");
        query("_supa_id = " + supaId("id-1"));
        query("_supa_job_id = " + jobId);
        LoadMode.MERGE;
        assertThat(query("SELECT value")).isEqualTo("winner");
    }

    @Test
    void assertsCallbackCountsAndErrorArtifactsForBadRows() {
        invalidRow();
        ErrorHandling.MODERATE;
        ErrorHandling.STRICT;
        assertThat(callbacks).isNotEmpty();
        assertThat(callbackStatus.getInputRowCount()).isEqualTo(2);
        assertThat(callbackStatus.getSuccessRowCount()).isEqualTo(1);
        assertThat(callbackStatus.getErrorRowCount()).isEqualTo(1);
        String artifact = Files.readString(errorPath);
        assertThat(artifact).contains("invalid row");
    }

    @Test
    void evolvesSchemaWithAddedColumnAndSupportedTypeWidening() {
        addColumn("note");
        assertThat(columns).contains("note");
        widenType("amount", "NUMERIC", "BIGNUMERIC");
        assertThat(type).isEqualTo("BIGNUMERIC");
    }

    @Test
    void mergeAppliesHardDelete() {
        write("_supa_deleted = TRUE");
        assertThat(queryCount("id-1")).isEqualTo(0);
    }

    @Test
    void overwritePreservesExistingPhysicalDesign() {
        LoadMode.OVERWRITE;
        assertThat(table.getClustering()).contains("customer_cluster");
    }

    @Test
    void concurrentColdSchemaFirstLoadsSucceed() {
        String uniqueSchema = newSchema();
        ExecutorService executor = newFixedThreadPool(2);
        invokeAll(executor, uniqueSchema, firstLoadA, firstLoadB);
        assertThat(query(uniqueSchema)).contains("a", "b");
    }
}
"""

GOOD_MERGE_TEST = """
class DemoLoaderSqlTest {
    @Test
    void mergeDeduplicatesByCursorThenSystemFields() {
        setCursorField(true);
        assertThat(sql)
            .contains("ROW_NUMBER PARTITION BY _supa_id")
            .contains("ORDER BY updated_at DESC, _supa_synced DESC, _supa_index DESC");
    }

    @Test
    void dedupFallsBackToSystemFields() {
        assertThat(order).isEqualTo("_supa_synced DESC, _supa_index DESC");
    }
}
"""

GOOD_MAPPER_TEST = (
    """
class DemoDataTypeMapperTest {
    @Test
    void documentsFreshDiscoveryReadback() {
        mapFromCanonicalType(type);
        mapTypeByName(nativeType);
"""
    + CANONICAL_REFERENCES
    + """
    }
}
"""
)

GOOD_JSON_TEST = r"""
class DemoConnectorContractTest {
    @Test
    void preservesJdbcJsonObjectArrayAndScalarText() {
        convertToCanonicalValue("{\"active\":true}", CanonicalType.JSON);
        convertToCanonicalValue("[1,2]", CanonicalType.JSON);
        convertToCanonicalValue("\"scalar\"", CanonicalType.JSON);
    }

    @Test
    void rejectsRawJdbcStructBecauseItOmitsFieldNames() {
        Struct struct = mock(Struct.class);
        assertThatThrownBy(() -> convertToCanonicalValue(struct, CanonicalType.JSON))
            .hasMessageContaining("field names");
    }
}
"""

GOOD_SCHEMA_PARITY_PERF_IT = """
class DemoSchemaDiscoveryParityPerfIT {
    @Test
    void bulkOnlyCatalogPathHasParityAndBoundedCost() {
        long start = System.nanoTime();
        List<ObjectMetadata> tablesOnly = connector.getObjectListBulkOnlyForTest();
        List<ObjectMetadata> fullMetadata =
            connector.getObjectAndFieldListBulkOnlyForTest();
        long elapsed = System.nanoTime() - start;
        assertThat(connector.getBulkFetchPath())
            .isEqualTo(BULK_INFORMATION_SCHEMA);
        assertThat(names(tablesOnly)).isEqualTo(names(fullMetadata));
        assertThat(metadataQueryCount).isLessThanOrEqualTo(datasetBatches * 3);
        assertThat(elapsed).isLessThan(MAX_ELAPSED);
        assertThat(fieldCount(fullMetadata)).isPositive();
    }

    @Test
    void optionalLegacyMetadataParity() {
        assumeTrue(Boolean.parseBoolean(System.getenv("RUN_LEGACY_PARITY")));
        assertMetadataEqual(
            connector.getObjectAndFieldListBulkOnlyForTest(),
            connector.getObjectAndFieldListUsingBaseForTest());
    }
}
"""


class VerifyJavaContractEvidenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self._temp_dir.name)
        (self.root / "pom.xml").write_text("<project/>", encoding="utf-8")
        enum_path = (
            self.root
            / "supaflow-core/src/main/java/io/supaflow/core/enums/CanonicalType.java"
        )
        enum_path.parent.mkdir(parents=True)
        enum_path.write_text(
            f"public enum CanonicalType {{ {CANONICAL_TYPES} }}",
            encoding="utf-8",
        )

        self.connector_dir = (
            self.root / "connectors/supaflow-connector-demo"
        )
        main_dir = self.connector_dir / "src/main/java/io/supaflow/connector/demo"
        test_dir = self.connector_dir / "src/test/java/io/supaflow/connector/demo"
        main_dir.mkdir(parents=True)
        test_dir.mkdir(parents=True)
        (main_dir / "DemoConnector.java").write_text(
            GOOD_CONNECTOR, encoding="utf-8"
        )
        self._write_test("DemoSourceConnectorIT.java", GOOD_SOURCE_IT)
        self._write_test("DemoAllTypesIT.java", GOOD_ALL_TYPES_IT)
        self._write_test("DemoDestinationIT.java", GOOD_DESTINATION_IT)
        self._write_test("DemoLoaderSqlTest.java", GOOD_MERGE_TEST)
        self._write_test("DemoDataTypeMapperTest.java", GOOD_MAPPER_TEST)
        self._write_test("DemoConnectorContractTest.java", GOOD_JSON_TEST)
        self._write_test(
            "DemoSchemaDiscoveryParityPerfIT.java",
            GOOD_SCHEMA_PARITY_PERF_IT,
        )

    def tearDown(self) -> None:
        self._temp_dir.cleanup()

    def _write_test(self, name: str, contents: str) -> None:
        path = (
            self.connector_dir
            / "src/test/java/io/supaflow/connector/demo"
            / name
        )
        path.write_text(contents, encoding="utf-8")

    def test_accepts_complete_cutoff_and_warehouse_evidence(self) -> None:
        self.assertEqual(
            [], MODULE.verify("cutoff-state", "demo", self.root)
        )
        self.assertEqual([], MODULE.verify("jdbc-source", "demo", self.root))
        self.assertEqual([], MODULE.verify("warehouse", "demo", self.root))

    def test_rejects_struct_conversion_without_lossless_source_projection(self) -> None:
        connector_file = (
            self.connector_dir
            / "src/main/java/io/supaflow/connector/demo/DemoConnector.java"
        )
        connector_file.write_text(
            GOOD_CONNECTOR.replace("TO_JSON_STRING", "LOSSY_STRUCT_TO_STRING"),
            encoding="utf-8",
        )

        failures = MODULE.verify("jdbc-source", "demo", self.root)

        self.assertTrue(
            any("lossless named JSON" in failure for failure in failures)
        )

    def test_allows_scalar_only_select_projection_without_nested_contract(self) -> None:
        connector_file = (
            self.connector_dir
            / "src/main/java/io/supaflow/connector/demo/DemoConnector.java"
        )
        connector_file.write_text(
            """
class DemoConnector extends BaseJdbcConnector {
    protected String renderSelectItem(FieldMetadata field) {
        return field.getFormattedName();
    }
    public Set<ConnectorCapabilities> getConnectorCapabilities() {
        return Set.of(ConnectorCapabilities.REPLICATION_SOURCE);
    }
}
""",
            encoding="utf-8",
        )

        self.assertEqual([], MODULE.verify("jdbc-source", "demo", self.root))

    def test_rejects_nested_source_it_without_named_field_assertions(self) -> None:
        bad_source = GOOD_SOURCE_IT.replace(
            'JsonNode nested = JSON.readTree(row.get("profile"));\n'
            '        assertThat(nested.get("name").asText()).isEqualTo("alice");',
            'String nested = String.valueOf(row.get("profile"));\n'
            "        assertThat(nested).isNotNull();",
        )
        self._write_test("DemoSourceConnectorIT.java", bad_source)

        failures = MODULE.verify("jdbc-source", "demo", self.root)

        self.assertTrue(
            any("named nested fields" in failure for failure in failures)
        )

    def test_rejects_bulk_perf_path_that_can_fall_back(self) -> None:
        connector_file = (
            self.connector_dir
            / "src/main/java/io/supaflow/connector/demo/DemoConnector.java"
        )
        connector_file.write_text(
            GOOD_CONNECTOR.replace(
                "getObjectAndFieldListBulkOnlyForTest",
                "getObjectAndFieldListForTest",
            ),
            encoding="utf-8",
        )
        self._write_test(
            "DemoSchemaDiscoveryParityPerfIT.java",
            GOOD_SCHEMA_PARITY_PERF_IT.replace(
                "getObjectListBulkOnlyForTest",
                "getObjectListForTest",
            ).replace(
                "getObjectAndFieldListBulkOnlyForTest",
                "getObjectAndFieldListForTest",
            ),
        )

        failures = MODULE.verify("jdbc-source", "demo", self.root)

        self.assertTrue(
            any("bulk-only fail-fast" in failure for failure in failures)
        )

    def test_rejects_bulk_perf_test_without_fetch_path_assertion(self) -> None:
        self._write_test(
            "DemoSchemaDiscoveryParityPerfIT.java",
            GOOD_SCHEMA_PARITY_PERF_IT.replace(
                'assertThat(connector.getBulkFetchPath())\n'
                "            .isEqualTo(BULK_INFORMATION_SCHEMA);",
                "",
            ),
        )

        failures = MODULE.verify("jdbc-source", "demo", self.root)

        self.assertTrue(
            any("bulk fetch-path assertion" in failure for failure in failures)
        )

    def test_rejects_empty_initial_cursor_advancement(self) -> None:
        bad_source = GOOD_SOURCE_IT.replace(
            "getEndCursorPosition()).isNull()",
            "getEndCursorPosition()).isNotNull()",
        )
        self._write_test("DemoSourceConnectorIT.java", bad_source)

        failures = MODULE.verify("cutoff-state", "demo", self.root)

        self.assertTrue(
            any("empty initial baseline" in failure for failure in failures)
        )

    def test_rejects_generic_canonical_type_token_as_all_types_evidence(self) -> None:
        self._write_test(
            "DemoAllTypesIT.java",
            "class DemoAllTypesIT { CanonicalType.STRING; }",
        )

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertTrue(
            any("missing canonical types" in failure for failure in failures)
        )
        self.assertTrue(
            any("semantic JSON assertions" in failure for failure in failures)
        )

    def test_rejects_incomplete_system_field_contract(self) -> None:
        self._write_test(
            "DemoDestinationIT.java",
            GOOD_DESTINATION_IT.replace("_supa_index", "input_index"),
        )

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertTrue(
            any("_supa_index" in failure for failure in failures)
        )

    def test_rejects_wrong_merge_tie_break_order(self) -> None:
        self._write_test(
            "DemoLoaderSqlTest.java",
            GOOD_MERGE_TEST.replace(
                "updated_at DESC, _supa_synced DESC, _supa_index DESC",
                "updated_at DESC, _supa_index DESC, _supa_synced DESC",
            ).replace(
                "_supa_synced DESC, _supa_index DESC",
                "_supa_index DESC, _supa_synced DESC",
            ),
        )

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertTrue(
            any("dedup ordering" in failure for failure in failures)
        )

    def test_accepts_quoted_merge_identifiers(self) -> None:
        quoted = GOOD_MERGE_TEST.replace(
            "updated_at DESC, _supa_synced DESC, _supa_index DESC",
            '\\"updated_at\\" DESC, \\"_supa_synced\\" DESC, \\"_supa_index\\" DESC',
        ).replace(
            "_supa_synced DESC, _supa_index DESC",
            '\\"_supa_synced\\" DESC, \\"_supa_index\\" DESC',
        )
        self._write_test("DemoLoaderSqlTest.java", quoted)

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertFalse(
            any("dedup ordering" in failure for failure in failures)
        )

    def test_classification_ignores_capabilities_in_comments(self) -> None:
        connector_file = (
            self.connector_dir
            / "src/main/java/io/supaflow/connector/demo/DemoConnector.java"
        )
        connector_file.write_text(
            """
class DemoConnector {
    public Set<ConnectorCapabilities> getConnectorCapabilities() {
        return Set.of(
            // ConnectorCapabilities.REPLICATION_SOURCE,
            // ConnectorCapabilities.READ,
            ConnectorCapabilities.REPLICATION_DESTINATION
            // ConnectorCapabilities.REVERSE_ETL_DESTINATION
        );
    }
    public ConnectorCapabilitiesConfig getCapabilitiesConfig() {
        return builder().asCloudWarehouse().requiresStaging(true).build();
    }
}
""",
            encoding="utf-8",
        )

        classification = MODULE.classify_connector(self.connector_dir)

        self.assertEqual(
            {
                "source": False,
                "destination": True,
                "activation": False,
                "warehouse": True,
                "direct": False,
                "invalid_read": False,
                "invalid_write": False,
                "invalid_schema_discovery": False,
            },
            classification,
        )

    def test_rejects_callback_collection_without_assertions(self) -> None:
        bad = GOOD_DESTINATION_IT.replace(
            "assertThat(callbacks).isNotEmpty();",
            "callbacks.add(callbackStatus);",
        ).replace(
            "assertThat(callbackStatus.getInputRowCount()).isEqualTo(2);",
            "callbackStatus.getInputRowCount();",
        ).replace(
            "assertThat(callbackStatus.getSuccessRowCount()).isEqualTo(1);",
            "callbackStatus.getSuccessRowCount();",
        ).replace(
            "assertThat(callbackStatus.getErrorRowCount()).isEqualTo(1);",
            "callbackStatus.getErrorRowCount();",
        )
        self._write_test("DemoDestinationIT.java", bad)

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertTrue(
            any("collecting callback objects is not evidence" in failure for failure in failures)
        )

    def test_rejects_configured_error_path_without_readback(self) -> None:
        bad = GOOD_DESTINATION_IT.replace(
            "String artifact = Files.readString(errorPath);",
            "String artifact = errorPath.toString();",
        )
        self._write_test("DemoDestinationIT.java", bad)

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertTrue(
            any("configuring errorPath is not evidence" in failure for failure in failures)
        )

    def test_rejects_additive_only_schema_evolution(self) -> None:
        bad = GOOD_DESTINATION_IT.replace(
            'widenType("amount", "NUMERIC", "BIGNUMERIC");',
            "keepTypeUnchanged();",
        ).replace(
            'assertThat(type).isEqualTo("BIGNUMERIC");',
            "assertThat(type).isNotNull();",
        )
        self._write_test("DemoDestinationIT.java", bad)

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertTrue(
            any("type-change/widening" in failure for failure in failures)
        )

    def test_rejects_advertised_hard_delete_without_live_proof(self) -> None:
        bad = GOOD_DESTINATION_IT.replace(
            'write("_supa_deleted = TRUE");',
            'write("_supa_deleted = FALSE");',
        )
        self._write_test("DemoDestinationIT.java", bad)

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertTrue(
            any("advertises hard deletes" in failure for failure in failures)
        )

    def test_rejects_destructive_load_without_physical_design_readback(self) -> None:
        connector_file = (
            self.connector_dir
            / "src/main/java/io/supaflow/connector/demo/DemoConnector.java"
        )
        connector_file.write_text(
            GOOD_CONNECTOR + "\nClustering design;\nLoadMode.OVERWRITE;\n",
            encoding="utf-8",
        )
        bad = GOOD_DESTINATION_IT.replace(
            'assertThat(table.getClustering()).contains("customer_cluster");',
            "assertThat(table).isNotNull();",
        )
        self._write_test("DemoDestinationIT.java", bad)

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertTrue(
            any("physical" in failure for failure in failures)
        )

    def test_rejects_concurrency_token_without_cold_schema_behavior(self) -> None:
        bad = GOOD_DESTINATION_IT.replace(
            """
    @Test
    void concurrentColdSchemaFirstLoadsSucceed() {
        String uniqueSchema = newSchema();
        ExecutorService executor = newFixedThreadPool(2);
        invokeAll(executor, uniqueSchema, firstLoadA, firstLoadB);
        assertThat(query(uniqueSchema)).contains("a", "b");
    }
""",
            """
    @Test
    void timeoutUsesConcurrentTimeUnit() {
        java.util.concurrent.TimeUnit.SECONDS.toMillis(30);
        assertThat(timeout).isPositive();
    }
""",
        )
        self._write_test("DemoDestinationIT.java", bad)

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertTrue(
            any("concurrent first loads" in failure for failure in failures)
        )

    def test_rejects_external_stage_without_scoped_cleanup_contract(self) -> None:
        main_file = (
            self.connector_dir
            / "src/main/java/io/supaflow/connector/demo/DemoConnector.java"
        )
        main_file.write_text(
            GOOD_CONNECTOR + "\nString gcsStagingBucket;\n",
            encoding="utf-8",
        )

        failures = MODULE.verify("warehouse", "demo", self.root)

        self.assertTrue(
            any("job-scoped prefix" in failure for failure in failures)
        )
        self.assertTrue(
            any("terminal cleanup" in failure for failure in failures)
        )
        self.assertTrue(
            any("lifecycle/retention" in failure for failure in failures)
        )
        self.assertTrue(
            any("prefix is empty" in failure for failure in failures)
        )
        self.assertTrue(
            any("failure-path cleanup" in failure for failure in failures)
        )


if __name__ == "__main__":
    unittest.main()
