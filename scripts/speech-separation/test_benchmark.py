from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

import numpy as np

from benchmark import cases_from_split


class BenchmarkTest(unittest.TestCase):
    def test_reads_full_code_switched_mixture_and_independent_reference(self):
        with TemporaryDirectory() as directory:
            dataset = Path(directory) / "ascend.npz"
            reference = np.full(48_000, 2_000, dtype=np.int16)
            target = np.full(70_000, 600, dtype=np.int16)
            interferer = np.full(70_000, 300, dtype=np.int16)
            np.savez(dataset, offsets=[0, len(target)], clean=target, interferer=interferer,
                     references=[reference], enrollments=[0], languages=["mixed"])

            [(_, language, mixture, enrolled, sources)] = cases_from_split(dataset)

        self.assertEqual(language, "mixed")
        self.assertEqual(len(mixture), 70_000)
        np.testing.assert_array_equal(enrolled, reference.astype(np.float32) / 32768)
        np.testing.assert_array_equal(sources[0], target.astype(np.float32) / 32768)
        np.testing.assert_array_equal(mixture, (target + interferer).astype(np.float32) / 32768)
