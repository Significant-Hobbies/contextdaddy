"""A matching HEAD alone must not qualify dirty or stale release inputs."""
import importlib.util
from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release-contextdaddy.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SHA = "a" * 40


class ReleaseSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Sources").mkdir()
        self.source = self.root / "Sources/App.swift"
        self.source.write_text("source")
        self.binary = self.root / "ContextDaddy"
        self.binary.write_bytes(b"built")
        os.utime(self.source, (100, 100))
        os.utime(self.binary, (200, 200))

    def validate(self, actual=SHA, status=""):
        with patch.object(release.subprocess, "check_output", side_effect=[actual + "\n", status]):
            release.validate_release_source(self.root, SHA, self.binary)

    def test_clean_matching_fresh_source_is_eligible(self):
        self.validate()

    def test_another_commit_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "checked-out source"):
            self.validate(actual="b" * 40)

    def test_modified_and_untracked_source_are_rejected(self):
        for status in [" M Sources/App.swift", "?? Sources/New.swift"]:
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "clean"):
                self.validate(status=status)

    def test_stale_binary_is_rejected(self):
        os.utime(self.source, (300, 300))
        with self.assertRaisesRegex(ValueError, "rebuild"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
