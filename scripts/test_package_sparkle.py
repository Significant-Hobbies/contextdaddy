import base64
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import sparkle_support


class ContextSparkleBundleTests(unittest.TestCase):
    def package(self, root, updates=False):
        with patch.object(sparkle_support, "ROOT", root), \
             patch.object(sparkle_support, "FRAMEWORK", root / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"), \
             patch.object(sparkle_support, "PUBLIC_KEY", root / "Support/SparklePublicKey.txt"), \
             patch("sys.argv", ["package-contextdaddy.py", str(root / "binary"), "--ccusage", str(root / "helper"), "--unsigned", "--output", str(root / "fixture.app"), *(["--enable-updates"] if updates else [])]), \
             patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, "ccusage 20.0.24\n", "")):
            runpy.run_path(str(root / "scripts/package-contextdaddy.py"), run_name="__main__")
        return plistlib.loads((root / "fixture.app/Contents/Info.plist").read_bytes())

    def fixture(self, root):
        (root / "scripts").mkdir()
        shutil.copy2(Path(__file__).with_name("package-contextdaddy.py"), root / "scripts/package-contextdaddy.py")
        for name in ("binary", "helper", "CONTEXTDADDY_NOTICES.md"):
            (root / name).write_text("fixture")
        fonts = root / "SaaSMakerUI_SaaSMakerUI.bundle/Fonts"
        fonts.mkdir(parents=True)
        (fonts / "Figtree.ttf").write_bytes(b"fixture font")
        (fonts / "Licenses").mkdir()
        (fonts / "Licenses/figtree-OFL.txt").write_text("fixture license")
        (root / "Support").mkdir()
        (root / "Support/ContextDaddy.icns").write_bytes(b"fixture")
        (root / "Assets").mkdir()
        for name in ("AIContext.png", "PageDoodles.png"):
            (root / "Assets" / name).write_bytes(b"fixture")
        framework = root / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        framework.mkdir(parents=True)
        (framework / "Sparkle").write_bytes(b"fixture")
        (root / ".build/artifacts/sparkle/Sparkle/LICENSE").write_text("Sparkle fixture license")

    def test_manual_bundle_contains_runtime_and_license_without_fake_feed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            info = self.package(root)
            self.assertNotIn("SUFeedURL", info)
            self.assertTrue((root / "fixture.app/Contents/Frameworks/Sparkle.framework/Sparkle").is_file())
            self.assertTrue((root / "fixture.app/Contents/Resources/Sparkle-LICENSE.txt").is_file())

    def test_dedicated_public_key_enables_owner_confirmed_feed_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            (root / "Support/SparklePublicKey.txt").write_text(base64.b64encode(bytes(range(32))).decode())
            info = self.package(root, updates=True)
            self.assertEqual(info["SUFeedURL"], "https://context.daddyrad.com/updates/appcast.xml")
            self.assertFalse(info["SUAllowsAutomaticUpdates"])
            self.assertFalse(info["SUSendProfileInfo"])

    def test_invalid_public_key_fails_before_creating_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            (root / "Support/SparklePublicKey.txt").write_text("invalid")
            with self.assertRaises(ValueError):
                self.package(root, updates=True)
            self.assertFalse((root / "fixture.app").exists())

    def test_ui_fonts_and_licenses_are_copied_next_to_existing_resources(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            self.package(root)
            resources = root / "fixture.app/Contents/Resources"
            fonts = resources / "SaaSMakerUI_SaaSMakerUI.bundle/Fonts"
            self.assertEqual((fonts / "Figtree.ttf").read_bytes(), b"fixture font")
            self.assertEqual((fonts / "Licenses/figtree-OFL.txt").read_text(), "fixture license")
            self.assertTrue((resources / "AIContext.png").is_file())
            # Repackaging an existing local app keeps the resource bundle available.
            self.package(root)
            self.assertTrue((fonts / "Figtree.ttf").is_file())

    def test_missing_ui_bundle_fails_before_mutating_existing_app(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            (root / "SaaSMakerUI_SaaSMakerUI.bundle").rename(root / "unrelated.bundle")
            app = root / "fixture.app"
            app.mkdir()
            marker = app / "existing"
            marker.write_text("preserve")
            with self.assertRaisesRegex(SystemExit, "Missing required SaaSMakerUI font resource bundle"):
                self.package(root)
            self.assertEqual(marker.read_text(), "preserve")
            self.assertFalse((app / "Contents").exists())
