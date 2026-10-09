import base64
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sparkle_support

class SparklePackagingTests(unittest.TestCase):
    def test_missing_or_invalid_key_blocks_packaging(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "public-key.txt"
            with patch.object(sparkle_support, "PUBLIC_KEY", path):
                with self.assertRaises(RuntimeError): sparkle_support.configuration()
                path.write_text("invalid public key")
                with self.assertRaises(ValueError): sparkle_support.configuration()
                path.write_text(base64.b64encode(b"too short").decode())
                with self.assertRaises(ValueError): sparkle_support.configuration()

    def test_signed_archive_verification_and_https_are_required(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "public-key.txt"
            path.write_text(base64.b64encode(bytes(range(32))).decode())
            with patch.object(sparkle_support, "PUBLIC_KEY", path):
                config = sparkle_support.configuration()
            self.assertTrue(config["SUVerifyUpdateBeforeExtraction"])
            self.assertTrue(config["SUFeedURL"].startswith("https://context.daddyrad.com/"))
            self.assertFalse(config["SUAllowsAutomaticUpdates"])
            self.assertFalse(config["SUSendProfileInfo"])

if __name__ == "__main__": unittest.main()
