"""Check an offline product against an explicitly supplied fixture directory.

historical-reopen and daemon-100k take exclusive, disposable state/ directories
at their original device and inode. historical-import needs only the archive.
The verifier creates private control sockets and import destinations under /tmp.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import platform
import shutil
import sqlite3
import subprocess
import tempfile
import time


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def command(binary, *args, timeout=55):
    result = subprocess.run(
        [binary, *args], capture_output=True, text=True, timeout=timeout,
        stdin=subprocess.DEVNULL,
    )
    if result.returncode:
        raise RuntimeError(f"{args} exited {result.returncode}: {result.stderr} {result.stdout}")
    return json.loads(result.stdout)


def configure(home, fixture, state):
    home.mkdir(mode=0o700)
    backups = home / "backups"
    backups.mkdir(mode=0o700)
    settings = json.loads((fixture / "config.json").read_bytes())
    require(settings.get("mode", "offline") == "offline", "expected an offline fixture")
    settings.update(
        namespace_path=str(state), backup_directory=str(backups),
        control_socket_path=str(home / "control"), current_uid=os.geteuid(),
    )
    config = home / "config.json"
    config.write_text(json.dumps(settings))
    return config


@contextlib.contextmanager
def serve(binary, config, ready_timeout=45, stop_timeout=45):
    with (config.parent / "serve.log").open("w+") as log:
        proc = subprocess.Popen(
            [binary, "serve", "--config", config], stdin=subprocess.DEVNULL,
            stdout=log, stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + ready_timeout
            while not (config.parent / "control").is_socket():
                if proc.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(f"serve exited {proc.returncode}: {log.read()}")
                require(time.monotonic() < deadline, "control socket deadline expired")
                time.sleep(0.05)
            yield
            require(proc.poll() is None, "daemon exited before shutdown")
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    code = proc.wait(stop_timeout)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                    raise
                if code:
                    log.seek(0)
                    raise RuntimeError(f"shutdown exited {code}: {log.read()}")


def import_archive(binary, fixture, report, home):
    config = configure(home, fixture, home / "state")
    archive = home / "backups" / "legacy-audit"
    shutil.copyfile(fixture / "backups" / archive.name, archive)
    archive.chmod(0o600)
    expected = bytes(report["export"]["data"]["digest"]).hex()
    require(digest(archive) == expected, "archive SHA-256 differs from historical export")
    with serve(binary, config):
        deadline = time.monotonic() + 180
        while True:
            imported = command(
                binary, "--config", config, "transfer", "import", archive,
                "--operation", "legacy-import",
            )
            if imported["data"]["phase"] == "materialized":
                break
            require(time.monotonic() < deadline, "import did not materialize")
            time.sleep(0.1)
        status = command(binary, "--config", config, "status")
        obligations = status["data"]["obligations"]
        require(len(obligations) == 1, "expected one imported obligation")
        item = obligations[0]
        require(item["head"]["told"] == report["head"]["told"], "import changed told head")
        require(item["ordinary_dispatch"] is False, "expected imported dispatch to be held")
    require(digest(archive) == expected, "import changed archive bytes")
    return expected


def reopen(binary, fixture, report, home):
    state = fixture / "state"
    config = configure(home, fixture, state)

    def files():
        return {p.relative_to(state): digest(p) for p in state.rglob("*") if p.is_file()}

    before = files()
    audit = command(binary, "--config", config, "namespace", "check")
    require(audit["report"]["native_closure"]["application_readability"] == "verified",
            "historical namespace readability was not verified")
    require(files() == before, "read-only audit changed historical namespace files")
    with serve(binary, config):
        task = command(binary, "--config", config, "task", "show", report["audit"]["data"]["task"])
        require(task["data"]["input"] == report["audit_task"]["data"]["input"],
                "reopened audit task input differs")
        item = command(binary, "--config", config, "monitor", "show", report["obligation"])["data"]
        for field in ("observed", "told"):
            require(item["head"][field] == report["head"][field], f"reopened {field} head differs")
        page = command(binary, "--config", config, "messages", report["obligation"])["data"]
        legacy = [message for message in page["messages"] if message["purpose"] == "activation"]
        require(legacy and all(message["state"].startswith("legacy_") for message in legacy),
                "expected the activation flagged legacy")
    require(files() == before, "reopening changed historical namespace files")


def check_100k(binary, fixture, report, home):
    state = fixture / "state"
    config = configure(home, fixture, state)
    expected = report["closed_files_sha256"]
    names = ("identity", "seal", "state.sqlite")
    require(set(expected) == set(names), "expected SHA-256 for identity, seal, and state.sqlite")

    def fingerprints():
        return {name: digest(state / name) for name in names}

    with (state / "owner.lock").open("rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require(fingerprints() == expected, "closed store differs from fixture report")
        uri = (state / "state.sqlite").as_uri() + "?mode=ro&immutable=1"
        with contextlib.closing(sqlite3.connect(uri, uri=True)) as db:
            tasks, = db.execute("SELECT count(*) FROM tasks").fetchone()
        require(tasks == 100_000, f"expected 100000 task rows, found {tasks}")
    manifest = command(binary, "describe-build")
    require(manifest["artifact_sha256"] == digest(binary), "product build digest differs")

    start = time.monotonic()
    with serve(binary, config, ready_timeout=120, stop_timeout=55):
        socket_seconds = time.monotonic() - start
        status = command(binary, "--config", config, "status", timeout=35)
        reply_seconds = time.monotonic() - start
        obligations = status["data"]["obligations"]
        require(status["status"] == "observed" and len(obligations) == 1, "expected one obligation")
        item = obligations[0]
        require(int(item["pending_directives_total"]) == 99_999, "wrong pending directive count")
        require(len(item["pending_directives"]) == 16, "expected first 16 pending directives")
        require(str(item["pending_directives_next"]) == "16", "expected continuation cursor 16")
    with (state / "owner.lock").open("rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require(fingerprints() == expected, "shutdown changed closed store fingerprints")
    return {
        "tasks": tasks, "pending_directives": 99_999, "page_count": 16, "cursor": 16,
        "socket_seconds": socket_seconds, "launch_to_status_seconds": reply_seconds,
        "closed_files_sha256": expected,
    }


def verify_producer(check, system, report, current_sha256):
    producers = {"77866577394711e6152a1e97fdecfeb0cfcd2f2c"}
    if check == "historical-reopen" and system == "Linux":
        producers.add("95a2f040029a38a46daf5be4d6dadff6c8c08dab")
    require(report.get("source_head") in producers, "expected historical source commit")
    prior = report.get("binary_sha256")
    require(isinstance(prior, str) and re.fullmatch(r"[0-9a-f]{64}", prior),
            "expected historical binary SHA-256")
    require(prior != current_sha256, "historical fixture names the current executable")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=("historical-import", "historical-reopen", "daemon-100k"))
    parser.add_argument("binary", type=Path)
    parser.add_argument("fixture", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    fixture = args.fixture.resolve(strict=True)
    report = json.loads((fixture / "report.json").read_bytes())
    binary_sha256 = digest(binary)
    if args.check.startswith("historical-"):
        verify_producer(args.check, platform.system(), report, binary_sha256)
    with tempfile.TemporaryDirectory(prefix="pf-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        if args.check == "daemon-100k":
            evidence = check_100k(binary, fixture, report, root / "scale")
        else:
            if args.check == "historical-reopen":
                reopen(binary, fixture, report, root / "reopen")
            evidence = {
                "source_head": report["source_head"],
                "source_binary_sha256": report["binary_sha256"],
                "archive_sha256": import_archive(binary, fixture, report, root / "import"),
            }
    require(digest(binary) == binary_sha256, "product changed during qualification")
    print(json.dumps({"check": args.check, "binary_sha256": binary_sha256, **evidence}))


if __name__ == "__main__":
    main()
