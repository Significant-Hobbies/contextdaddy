"""Common Sparkle bundle operations; each app supplies its own update policy."""

import base64
from pathlib import Path
import shutil
import subprocess
import uuid


def configuration(public_key: Path, feed_url: str, key_account: str, installer_launcher_service: bool = False) -> dict:
    if not public_key.is_file():
        raise RuntimeError(
            "Sparkle signing is not configured. Generate a dedicated Keychain key with "
            f"Sparkle's generate_keys --account {key_account}, then save ONLY its public key "
            "to Support/SparklePublicKey.txt."
        )
    key = public_key.read_text().strip()
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("Sparkle public key must decode to 32 bytes")
    config = {"SUFeedURL": feed_url, "SUPublicEDKey": key,
              "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": False,
              "SUAllowsAutomaticUpdates": False, "SUSendProfileInfo": False,
              "SUVerifyUpdateBeforeExtraction": True}
    if installer_launcher_service:
        config["SUEnableInstallerLauncherService"] = True
    return config


def embed(root: Path, framework: Path, app: Path) -> Path:
    if not framework.is_dir():
        raise RuntimeError("Resolve pinned Sparkle package before packaging")
    target = app / "Contents/Frameworks/Sparkle.framework"
    if target.exists():
        backup = root / "artifacts" / ("Sparkle.previous-" + uuid.uuid4().hex + ".framework")
        backup.parent.mkdir(exist_ok=True)
        target.rename(backup)
    shutil.copytree(framework, target, symlinks=True)
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / ".build/artifacts/sparkle/Sparkle/LICENSE", resources / "Sparkle-LICENSE.txt")
    return target


def sign(app: Path, identity: str, timestamp: bool = True) -> None:
    framework = app / "Contents/Frameworks/Sparkle.framework"
    version = framework / "Versions/B"
    targets = [version / "XPCServices/Downloader.xpc", version / "XPCServices/Installer.xpc",
               version / "Autoupdate", version / "Updater.app", framework]
    for target in targets:
        if not target.exists():
            raise RuntimeError(f"Missing Sparkle component: {target.name}")
        command = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
        if timestamp:
            command.append("--timestamp")
        subprocess.run(command + [str(target)], check=True)
