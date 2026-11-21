"""Create an offline compatibility fixture with a previously built legacy checkout."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from qualification_fixtures import digest, require, serve


LEGACY = "77866577394711e6152a1e97fdecfeb0cfcd2f2c"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("legacy_checkout", type=Path)
    parser.add_argument("destination", type=Path, help="new directory for the sealed namespace and archive")
    args = parser.parse_args()
    source = args.legacy_checkout.resolve(strict=True)
    binary = (source / "zig-out/bin/paredros").resolve(strict=True)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    require(head == LEGACY, f"expected legacy checkout {LEGACY}")
    require(not subprocess.check_output(["git", "status", "--porcelain"], cwd=source), "legacy checkout has edits")
    producer = digest(binary)
    fixture = args.destination.resolve()
    fixture.mkdir(parents=True, mode=0o700, exist_ok=False)
    backups = fixture / "backups"
    backups.mkdir(mode=0o700)

    with tempfile.TemporaryDirectory(prefix="pd-old-", dir="/tmp") as runtime:
        home = Path(runtime).resolve()
        config = home / "config.json"
        settings = {
            "version": 1, "current_uid": os.geteuid(), "namespace_path": str(fixture / "state"),
            "backup_directory": str(backups), "control_socket_path": str(home / "control"),
            "repository": {"account": "offline", "id": 1, "owner": "fixture", "name": "repository", "ref": "refs/heads/main"},
            "slack": {"account": "offline", "app": "A1", "workspace": "T1", "operator": "U1", "channel": "D1", "bot_id": "B1"},
        }
        config.write_text(json.dumps(settings))
        config.chmod(0o600)
        (fixture / "config.json").write_bytes(config.read_bytes())

        def cli(*argv, wait_for=None):
            deadline = time.monotonic() + 35
            while True:
                proc = subprocess.run([binary, "--config", config, *argv], capture_output=True,
                                      text=True, timeout=max(0.1, deadline - time.monotonic()))
                if proc.returncode == 0 or (wait_for and proc.returncode == 1):
                    data = json.loads(proc.stdout)
                    if wait_for is None or data["status"] == wait_for:
                        return data
                else:
                    raise RuntimeError(f"{argv}: {proc.stderr} {proc.stdout}")
                require(time.monotonic() < deadline, f"{argv}: {data}")
                time.sleep(0.1)

        with serve(binary, config):
            admitted = cli("monitor", "add", "--wording", "Legacy audit compatibility witness", "--operation", "legacy-genesis")
            obligation = admitted["data"]["task"]
            head_state = cli("monitor", "show", obligation, wait_for="observed")["data"]["head"]
            audit = cli("delivery", "audit", json.dumps(head_state["activation"]["key"]), "--operation", "legacy-audit", wait_for="admitted")
            audit_task = cli("task", "show", audit["data"]["task"])
            exported = cli("transfer", "export", "legacy-audit", "--snapshot", "--operation", "legacy-export")
        require(digest(backups / "legacy-audit") == bytes(exported["data"]["digest"]).hex(), "bad snapshot digest")
        report = {"source_head": head, "binary_sha256": producer, "obligation": obligation,
                  "head": head_state, "audit": audit, "audit_task": audit_task, "export": exported,
                  "namespace_check": cli("namespace", "check")}
    (fixture / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Created historical namespace and snapshot in {fixture}")


if __name__ == "__main__":
    main()
