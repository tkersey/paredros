"""Check an offline product against an explicitly supplied fixture directory.

daemon-100k takes an exclusive, disposable state/ directory at its original
device and inode. The verifier creates a private control socket under /tmp.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=("daemon-100k",))
    parser.add_argument("binary", type=Path)
    parser.add_argument("fixture", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    fixture = args.fixture.resolve(strict=True)
    report = json.loads((fixture / "report.json").read_bytes())
    binary_sha256 = digest(binary)
    with tempfile.TemporaryDirectory(prefix="pf-", dir="/tmp") as directory:
        evidence = check_100k(binary, fixture, report, Path(directory).resolve() / "scale")
    require(digest(binary) == binary_sha256, "product changed during qualification")
    print(json.dumps({"check": args.check, "binary_sha256": binary_sha256, **evidence}))


if __name__ == "__main__":
    main()
