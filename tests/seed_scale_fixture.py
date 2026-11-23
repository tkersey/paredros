"""Prepare a reusable offline daemon-scale namespace with the real native task seeder."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import time

from qualification_fixtures import digest


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def config(root):
    return {
        "version": 1, "current_uid": os.geteuid(), "mode": "offline",
        "namespace_path": str(root / "state"), "control_socket_path": str(root / "control"),
        "repository": {"account": "github-test", "id": 123, "owner": "owner",
                       "name": "test", "ref": "refs/heads/main"},
    }


def closed_fingerprints(state, target):
    database = state / "state.sqlite"
    db = sqlite3.connect(database.as_uri() + "?mode=ro&immutable=1", uri=True)
    try:
        if db.execute("SELECT count(*) FROM tasks").fetchone()[0] != target:
            raise ValueError("closed task count differs from requested fixture")
    finally:
        db.close()
    return {name: digest(state / name) for name in ("identity", "seal", "state.sqlite")}


def generate(root, product, seeder, target, batch_size, stop_requested):
    manifest = json.loads(subprocess.check_output([product, "describe-build"], timeout=30))
    product_hash = digest(product)
    if manifest["artifact_sha256"] != product_hash:
        raise ValueError("describe-build disagrees with the supplied product")
    source = {"namespace_path": str(root / "state"), "tasks": target,
              "product_sha256": product_hash, "seeder_sha256": digest(seeder)}
    root.parent.mkdir(parents=True, exist_ok=True)
    try:
        root.mkdir(mode=0o700)
    except FileExistsError:
        if not (root / "seed.json").is_file():
            raise ValueError(f"existing directory has no scale seeding receipt: {root}") from None

    with (root / "seed.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        receipt = root / "seed.json"
        settings = root / "config.json"
        if receipt.exists():
            progress = json.loads(receipt.read_text())
            if progress["source"] != source or json.loads(settings.read_text()) != config(root):
                raise ValueError("fixture producer, target, path, or configuration changed")
        else:
            save(settings, config(root))
            settings.chmod(0o600)
            progress = {"source": source, "last_directive": 0}
            save(receipt, progress)

        state = root / "state"
        report = root / "report.json"
        if report.exists():
            finished = json.loads(report.read_text())
            with (state / "owner.lock").open("rb") as owner:
                fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if (progress["last_directive"] != target - 1
                        or any(finished.get(key) != value for key, value in source.items())
                        or finished["terminal_tasks"] != target or finished["obligations"] != 1
                        or finished["closed_files_sha256"] != closed_fingerprints(state, target)):
                    raise ValueError("completed fixture differs from its original receipt")
            print(f"Verified prepared fixture with {target} tasks at {root}", flush=True)
            return

        env = dict(os.environ, PAREDROS_SCALE_PATH=str(root / "state"),
                   PAREDROS_SCALE_CONFIG=str(settings), PAREDROS_SCALE_RUNTIME=product_hash)
        def invoke(mode, **arguments):
            if digest(seeder) != source["seeder_sha256"]:
                raise ValueError("scale seeder changed during setup")
            result = subprocess.run(
                [seeder], cwd=root, env=dict(env, PAREDROS_SCALE_MODE=mode, **arguments),
                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                pass_fds=(lock.fileno(),), start_new_session=True,
            )
            if result.returncode:
                raise RuntimeError(f"scale {mode} exited {result.returncode}: {result.stderr}")
            return [json.loads(line) for line in result.stdout.splitlines()]

        while progress["last_directive"] < target - 1:
            if stop_requested():
                raise SystemExit(128 + stop_requested())
            first = progress["last_directive"] + 1
            last = min(first + batch_size - 1, target - 1)
            started = time.monotonic()
            rows = invoke("seed", PAREDROS_SCALE_FIRST=str(first), PAREDROS_SCALE_LAST=str(last))
            if [row["directive"] for row in rows] != list(range(first, last + 1)):
                raise ValueError("seeder did not complete every selected directive")
            # Only acknowledge a closed batch. Replaying a completed batch uses stable operation IDs.
            progress["last_directive"] = last
            save(receipt, progress)
            print(f"Seeded {last + 1}/{target} tasks ({time.monotonic() - started:.1f}s for this batch)", flush=True)

        if stop_requested():
            raise SystemExit(128 + stop_requested())
        measurement, = invoke("measure")
        if measurement["terminal_tasks"] != target or measurement["obligations"] != 1:
            raise ValueError("native catalog count differs from requested fixture")
        with (state / "owner.lock").open("rb") as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fingerprints = closed_fingerprints(state, target)
            save(report, dict(source, **measurement, closed_files_sha256=fingerprints))
        print(f"Prepared {target} tasks at {root}", flush=True)


def main():
    stopping = 0

    def terminate(signum, frame):
        nonlocal stopping
        stopping = signum
        print("Pausing after the current batch closes", flush=True)

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="Ctrl-C closes the current batch. Repeat the command with the same producer to resume.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--product", type=Path, default=Path("zig-out/bin/paredros"), help="offline product")
    parser.add_argument("--seeder", type=Path, default=Path("zig-out/test-tools/paredros-scale"),
                        help="native seeder from the same build")
    parser.add_argument("--output", type=Path,
                        default=Path(os.environ.get("PAREDROS_HISTORY_100K", ".zig-cache/qualification-fixtures/100k")),
                        help="dedicated new or previously seeded directory")
    parser.add_argument("--tasks", type=int, default=100_000, help="total tasks, including genesis")
    parser.add_argument("--batch-size", type=int, default=4096, help="directives per progress checkpoint")
    args = parser.parse_args()
    if not 2 <= args.tasks <= 100_000 or not 1 <= args.batch_size <= 4096:
        parser.error("tasks must be 2..100000 and batch size must be 1..4096")
    generate(args.output.resolve(), args.product.resolve(strict=True),
             args.seeder.resolve(strict=True), args.tasks, args.batch_size, lambda: stopping)


if __name__ == "__main__":
    main()
