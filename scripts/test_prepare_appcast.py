import base64
import hashlib
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import sparkle_support


class ContextAppcastTests(unittest.TestCase):
    def fixture(self, root):
        release = root / "release"
        release.mkdir()
        source = release / "ContextDaddy-0.3.0-20-arm64.dmg"
        source.write_bytes(b"synthetic qualified artifact")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        (release / "SHA256SUMS").write_text(f"{digest}  {source.name}\n")
        return source, digest

    def prepare(self, root, source):
        output = root / "feed"
        calls = []
        def command(args, **kwargs):
            calls.append((args, kwargs))
            if "generate_appcast" in str(args[0]):
                signature = base64.b64encode(b"x" * 64).decode()
                (output / "appcast.xml").write_text(
                    '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                    '<sparkle:version>20</sparkle:version><sparkle:shortVersionString>0.3.0</sparkle:shortVersionString>'
                    f'<enclosure url="https://context.daddyrad.com/updates/{source.name}" length="{source.stat().st_size}" '
                    f'sparkle:edSignature="{signature}"/></item></channel></rss>')
            return subprocess.CompletedProcess(args, 0)
        with patch.object(sparkle_support, "configuration", return_value={}), \
             patch.object(sparkle_support, "ROOT", root), \
             patch("subprocess.run", side_effect=command), \
             patch.dict("os.environ", {"SPARKLE_ED25519_PRIVATE_KEY": "synthetic-input"}, clear=True), \
             patch("sys.argv", ["prepare-appcast.py", str(source.parent), str(output), "--ed-key-stdin"]), \
             patch("builtins.print"):
            runpy.run_path(str(Path(__file__).with_name("prepare-appcast.py")), run_name="__main__")
        return output, calls

    def test_feed_binds_the_original_bootstrap_bytes_and_context_url(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, digest = self.fixture(root)
            output, calls = self.prepare(root, source)
            self.assertEqual((output / source.name).read_bytes(), source.read_bytes())
            self.assertEqual(calls[0][0][0], "codesign")
            self.assertEqual(calls[1][0][:3], ["xcrun", "stapler", "validate"])
            self.assertIn("--ed-key-file", calls[2][0])
            self.assertEqual(calls[2][1]["input"], "synthetic-input")
            self.assertIn(source.name, (output / "appcast.xml").read_text())

    def test_modified_qualified_bytes_never_stage_a_feed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, digest = self.fixture(root)
            source.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                self.prepare(root, source)
            self.assertFalse((root / "feed").exists())
