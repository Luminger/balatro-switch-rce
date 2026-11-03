"""Offline schema/privacy tests; no console or previous backup ZIP required."""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import jksv_meta


class MetadataTests(unittest.TestCase):
    def test_fixed_revision_and_privacy(self):
        data = jksv_meta.encode(timestamp=123456789)
        self.assertEqual(len(data), 86)
        self.assertEqual(data[:5], b"JKSV\x01")
        self.assertEqual(data[13:29], bytes(16))
        parsed = jksv_meta.decode(data)
        self.assertEqual(parsed["account_uid"], "00" * 16)
        self.assertEqual(parsed["application_id"], "0100cd801ce5e000")
        self.assertEqual(parsed["data_size"], 16 * 1024 * 1024)
        self.assertEqual(parsed["journal_size"], 16 * 1024 * 1024)
        self.assertEqual(parsed["save_type"], 1)
        self.assertEqual(parsed["space_id"], 1)
        self.assertEqual(parsed["commit_id"], 0)

    def test_rejects_corruption(self):
        valid = jksv_meta.encode(timestamp=123)
        with self.assertRaises(ValueError):
            jksv_meta.decode(valid[:-1])
        with self.assertRaises(ValueError):
            jksv_meta.decode(b"BAD!" + valid[4:])


if __name__ == "__main__":
    unittest.main()
