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
    / "verify_python_dlt_connector.py"
)
SPEC = importlib.util.spec_from_file_location("verify_python_dlt_connector", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


GOOD_CONNECTOR = """
class DemoConnector(DeclarativeDltConnector):
    def _create_source(
        self,
        resource,
        cutoff_time=None,
        effective_start=None,
        selected_fields=None,
        selected_child_objects=None,
    ):
        return demo_source(selected_fields=selected_fields)
"""

IGNORES_SELECTION = """
class DemoConnector(DeclarativeDltConnector):
    def _create_source(
        self,
        resource,
        cutoff_time=None,
        effective_start=None,
        selected_fields=None,
        selected_child_objects=None,
    ):
        return demo_source()
"""

GOOD_UNIT_TEST = """
def test_selected_fields_incremental_sync_token():
    selected_fields = {"id", "name"}
    row = {"id": "1", "name": "A"}
    assert "description" not in row
"""

GOOD_INTEGRATION_TEST = """
def test_sparse_projection():
    ReadHarness(selected_fields_factory=lambda obj: obj.fields)
"""


class VerifyPythonDltConnectorTest(unittest.TestCase):
    def _platform(
        self,
        *,
        connector: str = GOOD_CONNECTOR,
        unit_test: str = GOOD_UNIT_TEST,
        integration_test: str = GOOD_INTEGRATION_TEST,
    ) -> Path:
        root = Path(self._temp_dir.name)
        connector_dir = root / "python/connectors/supaflow_connector_demo"
        connector_dir.mkdir(parents=True)
        (connector_dir / "connector.py").write_text(connector, encoding="utf-8")

        tests_dir = root / "python/tests"
        integration_dir = tests_dir / "integration"
        integration_dir.mkdir(parents=True)
        (tests_dir / "test_demo_connector.py").write_text(
            unit_test, encoding="utf-8"
        )
        (integration_dir / "test_demo_read_harness_e2e.py").write_text(
            integration_test, encoding="utf-8"
        )
        return root

    def setUp(self) -> None:
        self._temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self._temp_dir.cleanup()

    def test_accepts_connector_with_behavioral_projection_evidence(self) -> None:
        failures = MODULE.verify("demo", self._platform())
        self.assertEqual([], failures)

    def test_rejects_selected_fields_argument_that_is_never_consumed(self) -> None:
        failures = MODULE.verify(
            "demo", self._platform(connector=IGNORES_SELECTION)
        )
        self.assertIn(
            "_create_source accepts selected_fields but never consumes it",
            failures,
        )

    def test_rejects_missing_source_projection_regression(self) -> None:
        failures = MODULE.verify(
            "demo", self._platform(unit_test="def test_connection(): pass\n")
        )
        self.assertTrue(
            any("Missing source/adapter unit coverage" in item for item in failures)
        )

    def test_rejects_missing_read_harness_projection_regression(self) -> None:
        failures = MODULE.verify(
            "demo", self._platform(integration_test="def test_read(): pass\n")
        )
        self.assertTrue(
            any("Missing live/read-harness sparse projection" in item for item in failures)
        )


if __name__ == "__main__":
    unittest.main()

