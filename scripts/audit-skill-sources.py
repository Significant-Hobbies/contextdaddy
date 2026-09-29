#!/usr/bin/env python3
"""Read-only provenance report powered by ASM and Vercel skills inventory.

Does not install/update/remove skills or edit either tool's state. npm may
populate its package cache. Source claims are recorded provenance, not proof
that installed contents still match upstream.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
from urllib.parse import urlsplit


def run_json(command, cwd):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                            timeout=90, env={**os.environ, "DISABLE_TELEMETRY": "1"})
    if result.returncode:
        raise RuntimeError(f"Inventory command failed: {command[0]} (exit {result.returncode})")
    return json.loads(result.stdout)


def github_url(value):
    """Only expose ordinary credential-free GitHub repository URLs."""
    parts = urlsplit(value or "")
    if (parts.scheme == "https" and parts.hostname == "github.com"
            and not parts.username and not parts.password and not parts.query
            and not parts.fragment and len(parts.path.strip("/").split("/")) == 2):
        return value.removesuffix(".git")
    return None


def reconcile(inventory, listings, lock, home):
    sources = {}
    for item in listings:
        sources.setdefault(str(Path(item["path"]).resolve()), []).append(item)
    rows = []
    for item in inventory:
        path = str(Path(item["path"]).resolve())
        row = {key: item.get(key) for key in
               ("name", "path", "scope", "provider", "providerLabel", "isSymlink")}
        row["canonicalPath"] = path
        row["contentMatch"] = "not checked"
        if item.get("provider") in ("plugin", "codex-plugin"):
            row.update(status="plugin-owned", updateOwner=item.get("providerLabel"),
                       marketplace=item.get("marketplace"), github=None)
        else:
            matches = [s for s in sources.get(path, []) if github_url(s.get("sourceUrl"))]
            urls = {github_url(s.get("sourceUrl")) for s in matches}
            if len(urls) == 1:
                source = matches[0]
                row.update(status="recorded-github-source", github=urls.pop(),
                           updateOwner="Vercel skills", evidence="skills list --json, resolved path")
                # Lock keys alone cannot establish identity. Require the canonical
                # global install path and repository to agree before attaching hash.
                for name, entry in lock.get("skills", {}).items():
                    expected = str((home / ".agents/skills" / name).resolve())
                    if expected == path and github_url(entry.get("sourceUrl")) == row["github"]:
                        row.update(skillPath=entry.get("skillPath"),
                                   installedFolderHash=entry.get("skillFolderHash"))
            else:
                row.update(status="source-unresolved", github=None, updateOwner=None)
        rows.append(row)
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--folder", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    folder = args.folder.resolve()
    command = ["npx", "--yes", "skills@1.7.0", "list"]
    inventory = run_json(["asm", "list", "--json"], folder)
    listings = run_json(command + ["-g", "--json"], folder)
    listings += run_json(command + ["--json"], folder)
    home = Path.home()
    lock_path = home / ".agents/.skill-lock.json"
    lock = json.loads(lock_path.read_text()) if lock_path.exists() else {}
    rows = reconcile(inventory, listings, lock, home)
    counts = {status: sum(row["status"] == status for row in rows)
              for status in sorted({row["status"] for row in rows})}
    report = {
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "folder": str(folder), "countsByInstallation": counts,
        "credits": {"inventory": "https://github.com/luongnv89/agent-skill-manager",
                    "sources": "https://github.com/vercel-labs/skills"},
        "limitations": ["ASM coverage is not an effective agent context scan; parent folders may be omitted.",
                        "Plugin entries may represent bundles or marketplace files, not enabled skills.",
                        "Recorded source does not verify current content or local modifications.",
                        "Unresolved does not mean external: local authorship also needs evidence."],
        "installations": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"folder": str(folder), "installations": len(rows),
                      "sources": counts, "report": str(args.output)}, indent=2))


if __name__ == "__main__":
    main()
