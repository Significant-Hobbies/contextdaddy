#!/usr/bin/env python3
"""Build a signed, notarized ContextDaddy DMG; publishing is a separate step."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def run(*command, **kwargs):
    return subprocess.run([str(part) for part in command], check=True, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True, help="Installed Developer ID Application identity")
    parser.add_argument("--notary-profile", help="Existing Keychain profile name; never pass credentials")
    parser.add_argument("--notary-api-key", type=Path, help="Path to protected App Store Connect API key")
    parser.add_argument("--notary-key-id", help="App Store Connect API key identifier")
    parser.add_argument("--notary-issuer-id", help="App Store Connect issuer identifier")
    parser.add_argument("--ccusage", required=True, type=Path, help="Pinned ccusage 20.0.24 executable")
    parser.add_argument("--output", required=True, type=Path, help="New output directory; never overwritten")
    parser.add_argument("--version", required=True, help="Release version")
    parser.add_argument("--build", type=int, required=True, help="Release build number")
    parser.add_argument("--source-sha", required=True, help="Exact tagged source commit")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_sha):
        parser.error("--source-sha must be a full commit hash")
    source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if source_sha != args.source_sha:
        parser.error("--source-sha does not match the checked-out source")
    api_auth = [args.notary_api_key, args.notary_key_id, args.notary_issuer_id]
    if (args.notary_profile and any(api_auth)) or (any(api_auth) and not all(api_auth)) or not (args.notary_profile or all(api_auth)):
        parser.error("Pass a Keychain profile or the complete API key, key ID, and issuer ID")

    binary = ROOT / ".build/release/ContextDaddy"
    if not binary.is_file():
        parser.error("Build the release executable first with swift build -c release")
    if args.output.exists():
        parser.error(f"Output already exists: {args.output}")
    if not args.ccusage.is_file():
        parser.error(f"ccusage helper does not exist: {args.ccusage}")
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture_output=True, text=True).stdout
    if not any(args.identity in line and "Developer ID Application" in line
               for line in identities.splitlines()):
        parser.error("The requested Developer ID Application identity is not installed")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    stage = output / "image-contents"
    stage.mkdir()
    app = stage / "ContextDaddy.app"
    run(sys.executable, ROOT / "scripts/package-contextdaddy.py", binary,
        "--ccusage", args.ccusage.resolve(), "--output", app, "--unsigned",
        "--version", args.version, "--build", args.build)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    helper = app / "Contents/Helpers/ccusage"
    run("codesign", "--force", "--sign", args.identity, "--timestamp", "--options", "runtime", helper)
    run("codesign", "--force", "--sign", args.identity, "--timestamp", "--options", "runtime", app)
    run("codesign", "--verify", "--deep", "--strict", app)

    (stage / "Applications").symlink_to("/Applications")
    shutil.copy2(ROOT / "CONTEXTDADDY_DISTRIBUTION.md", stage / "Start Here.txt")
    version = info["CFBundleShortVersionString"]
    dmg = output / f"ContextDaddy-{version}-{info['CFBundleVersion']}-arm64.dmg"
    run("hdiutil", "create", "-volname", "ContextDaddy", "-srcfolder", stage,
        "-format", "UDZO", dmg)
    run("codesign", "--force", "--sign", args.identity, "--timestamp", dmg)
    run("hdiutil", "verify", dmg)
    receipt = {
        "version": version,
        "build": info["CFBundleVersion"],
        "architecture": "arm64",
        "signed": True,
        "hardenedRuntime": True,
        "notarized": False,
        "stapled": False,
        "publicReady": False,
        "sourceBinarySha256": sha256(binary),
        "helperSha256": sha256(args.ccusage),
        "dmgSha256": sha256(dmg),
        "sourceSha": args.source_sha,
    }
    receipt_path = output / "release-receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")

    auth = (["--keychain-profile", args.notary_profile] if args.notary_profile else
            ["--key", args.notary_api_key, "--key-id", args.notary_key_id,
             "--issuer", args.notary_issuer_id])
    result = run("xcrun", "notarytool", "submit", dmg, *auth, "--wait",
                 "--output-format", "json", capture_output=True, text=True)
    notarization = json.loads(result.stdout)
    (output / "notarization.json").write_text(json.dumps(notarization, indent=2) + "\n")
    if notarization.get("status") != "Accepted":
        raise SystemExit("Apple did not accept the candidate; see notarization.json")
    run("xcrun", "stapler", "staple", dmg)
    run("xcrun", "stapler", "validate", dmg)
    run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg)
    receipt.update(notarized=True, stapled=True, dmgSha256=sha256(dmg))
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    (output / "SHA256SUMS").write_text(f"{sha256(dmg)}  {dmg.name}\n")
    print(f"Notarized candidate: {dmg}")
    print("Run the installed-app smoke test and publish only after release qualification.")


if __name__ == "__main__":
    main()
