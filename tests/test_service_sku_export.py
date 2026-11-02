import os
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(os.name == "nt", "Standalone exporter requires Windows PowerShell")
class ServiceSkuExportTests(unittest.TestCase):
    def test_read_only_exporter_with_synthetic_azure_responses(self):
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.run(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                 "-File", str(Path(__file__).with_suffix(".ps1")), "-TestDirectory", directory],
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
                check=False,
            )
            self.assertEqual(0, process.returncode, process.stdout + process.stderr)
            self.assertIn("Synthetic service SKU exporter checks passed.", process.stdout)
