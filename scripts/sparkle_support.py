"""App-owned Sparkle settings backed by the shared Daddy packaging core."""
from pathlib import Path
import sparkle_core

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORK = ROOT / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
PUBLIC_KEY = ROOT / "Support/SparklePublicKey.txt"
FEED_URL = "https://context.daddyrad.com/updates/appcast.xml"
KEY_ACCOUNT = "contextdaddy-updates"

def configuration():
    return sparkle_core.configuration(PUBLIC_KEY, FEED_URL, KEY_ACCOUNT)

def embed(app):
    return sparkle_core.embed(ROOT, FRAMEWORK, app)

def sign(app, identity, timestamp=True):
    return sparkle_core.sign(app, identity, timestamp)
