"""Package an already-built ContextDaddy executable as a local development app."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import sparkle_support

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("binary", nargs="?", type=Path)
parser.add_argument("--ccusage", type=Path, help="Pinned ccusage 20.0.24 executable to bundle")
parser.add_argument("--output", type=Path, default=root / "artifacts/ContextDaddy.app")
parser.add_argument("--enable-updates", action="store_true", help="Require the dedicated Sparkle feed public key")
parser.add_argument("--unsigned", action="store_true", help="Leave signing to the distribution packager")
parser.add_argument("--version", default="0.1.0", help="Package version")
parser.add_argument("--build", type=int, default=1, help="Package build number")
args = parser.parse_args()
if not all(part.isdigit() for part in args.version.split(".")) or args.build < 1:
    parser.error("Version must be numeric and build must be positive")

if args.binary is None:
    candidates = [
        root / ".build/out/Products/Release/ContextDaddy",
        root / ".build/release/ContextDaddy",
        root / ".build/out/Products/Debug/ContextDaddy",
        root / ".build/debug/ContextDaddy",
    ]
    existing = [candidate for candidate in candidates if candidate.is_file()]
    if not existing:
        raise SystemExit("Build ContextDaddy first; no release or debug executable was found.")
    args.binary = max(existing, key=lambda candidate: candidate.stat().st_mtime)

if not args.binary.is_file():
    raise SystemExit(f"Build ContextDaddy first: {args.binary}")

# SwiftPM's Bundle.module accessor requires its font bundle in packaged apps.
# Resolve it beside the selected binary, never from a different configuration.
ui_bundle = args.binary.parent / "SaaSMakerUI_SaaSMakerUI.bundle"
if not ui_bundle.is_dir():
    raise SystemExit(f"Missing required SaaSMakerUI font resource bundle: {ui_bundle}. "
                     "Build ContextDaddy with SwiftPM before packaging.")

# Validate helper and attribution before mutating an existing app bundle.
ccusage_candidates = ([args.ccusage] if args.ccusage else []) + [
    root / "artifacts/ContextDaddy.app/Contents/Helpers/ccusage",
    Path.home() / ".local/bin/ccusage",
    Path("/opt/homebrew/bin/ccusage"),
    Path("/usr/local/bin/ccusage"),
]
ccusage = next((candidate for candidate in ccusage_candidates if candidate and candidate.is_file()), None)
if ccusage is None:
    raise SystemExit("A ccusage 20.0.24 executable is required; pass --ccusage <path>.")
version = subprocess.run([str(ccusage), "--version"], capture_output=True, text=True, check=True, timeout=10)
if version.stdout.strip() != "ccusage 20.0.24":
    raise SystemExit(f"Expected ccusage 20.0.24, got: {version.stdout.strip()!r}")
if not (root / "CONTEXTDADDY_NOTICES.md").is_file():
    raise SystemExit("Missing ccusage attribution and MIT notice.")

# Manual distribution remains available until the dedicated feed key is configured.
update_configuration = sparkle_support.configuration() if args.enable_updates else {}
bundle = args.output
contents = bundle / "Contents"
executable = contents / "MacOS/ContextDaddy"
contents.joinpath("MacOS").mkdir(parents=True, exist_ok=True)
resources = contents / "Resources"
resources.mkdir(parents=True, exist_ok=True)
shutil.copytree(ui_bundle, resources / ui_bundle.name, dirs_exist_ok=True)
pending = executable.with_suffix(".pending")
shutil.copy2(args.binary, pending)
pending.chmod(0o755)
pending.replace(executable)

for asset_name in ["AIContext.png", "PageDoodles.png"]:
    source = root / "Assets" / asset_name
    if not source.is_file():
        raise SystemExit(f"Missing required artwork: {source}")
    shutil.copy2(source, resources / asset_name)
icon = root / "Support/ContextDaddy.icns"
if not icon.is_file():
    raise SystemExit(f"Missing required icon: {icon}")
shutil.copy2(icon, resources / icon.name)

# The packaged app owns its pinned helper and never launches another product.
helpers = contents / "Helpers"
helpers.mkdir(parents=True, exist_ok=True)
if ccusage.resolve() != (helpers / "ccusage").resolve():
    shutil.copy2(ccusage, helpers / "ccusage")
(helpers / "ccusage").chmod(0o755)
shutil.copy2(root / "CONTEXTDADDY_NOTICES.md", resources / "CONTEXTDADDY_NOTICES.md")

sparkle_support.embed(bundle)

with contents.joinpath("Info.plist").open("wb") as handle:
    plistlib.dump({
        "CFBundleExecutable": "ContextDaddy",
        "CFBundleIdentifier": "com.significanthobbies.contextdaddy",
        "CFBundleName": "ContextDaddy",
        "CFBundleDisplayName": "ContextDaddy",
        "CFBundleIconFile": "ContextDaddy.icns",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": args.version,
        "CFBundleVersion": str(args.build),
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
        **update_configuration,
    }, handle)

if not args.unsigned:
    sparkle_support.sign(bundle, "-", timestamp=False)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)], check=True)
    registration = subprocess.run([
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        "-f", str(bundle),
    ], check=False)
    if registration.returncode != 0:
        print("Warning: the app was packaged and signed, but LaunchServices registration did not refresh.")
print(f"Packaged {args.binary} -> {bundle}")
