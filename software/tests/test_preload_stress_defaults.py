from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import patch


SOFTWARE_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOFTWARE_DIR))

import preload_stress_test


class PreloadStressDefaultsTests(unittest.TestCase):
    def test_port_memory_bases_are_bank_local(self) -> None:
        with patch.object(sys, "argv", ["preload_stress_test.py", "--port", "0"]):
            port0 = preload_stress_test.parse_args()
        with patch.object(sys, "argv", ["preload_stress_test.py", "--port", "1"]):
            port1 = preload_stress_test.parse_args()

        self.assertEqual((port0.desc_base, port0.data_base), (0x0000_0000, 0x1000_0000))
        self.assertEqual((port1.desc_base, port1.data_base), (0x4_0000_0000, 0x4_1000_0000))


if __name__ == "__main__":
    unittest.main()
