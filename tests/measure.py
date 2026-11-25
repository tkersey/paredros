import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import statistics
import subprocess
import time
from urllib.parse import quote


def distribution(values):
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "minimum": ordered[0],
        "median": statistics.median(ordered),
        "p95_nearest_rank": ordered[math.ceil(len(ordered) * 0.95) - 1],
        "maximum": ordered[-1],
    }


def retained(root):
    state = root / "state"
    uri = "file:" + quote(str(state / "state.sqlite"), safe="/") + "?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        names = [row[0] for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )]
        counts = {
            name: connection.execute(
                'SELECT count(*) FROM "' + name.replace('"', '""') + '"'
            ).fetchone()[0]
            for name in names
        }
    return {
        "store_rows": counts,
        "namespace_bytes": sum(path.stat().st_size for path in state.rglob("*") if path.is_file()),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--mode", choices=("scale", "empty", "daemon"), default="scale")
    parser.add_argument("--targets", type=int, nargs="+", default=[10000, 100000])
    parser.add_argument("--history", type=int, default=0)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    targets = sorted(set(args.targets))
    if not targets or targets[0] < 2 or targets[-1] > 100000:
        parser.error("targets must be between 2 and 100000")
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    root = args.output.resolve(strict=True)
    identity = hashlib.sha256(binary.read_bytes()).hexdigest()
    report = {
        "binary_sha256": identity,
        "platform": platform.platform(),
        "mode": args.mode,
        "measurements": [],
    }

    def invoke(mode, first=None, last=None, **extra):
        if hashlib.sha256(binary.read_bytes()).hexdigest() != identity:
            raise RuntimeError("measurement binary changed")
        env = os.environ.copy()
        env.update(PAREDROS_SCALE_PATH=str(root / "state"), PAREDROS_SCALE_MODE=mode)
        if first is not None:
            env.update(PAREDROS_SCALE_FIRST=str(first), PAREDROS_SCALE_LAST=str(last))
        env.update(extra)
        started = time.monotonic()
        result = subprocess.run(
            [str(binary)], env=env, capture_output=True, text=True, timeout=args.timeout,
        )
        label = "-".join([mode, str(first), str(last), *extra.values()])
        (root / f"{label}.jsonl").write_text(result.stdout)
        (root / f"{label}.stderr").write_text(result.stderr)
        result.check_returncode()
        return [json.loads(line) for line in result.stdout.splitlines()], time.monotonic() - started

    def save(measurement):
        report["measurements"].append(measurement)
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(measurement), flush=True)

    if args.mode == "daemon":
        if args.fixture:
            shutil.copytree(args.fixture.resolve(strict=True) / "state", root / "state")
        else:
            invoke("empty", PAREDROS_EMPTY_PHASE="seed", PAREDROS_EMPTY_HISTORY=str(args.history))
        rows, elapsed = invoke("empty", PAREDROS_EMPTY_PHASE="daemon")
        attach = [row for row in rows if "daemon_attach_nanoseconds" in row]
        checks = [row for row in rows if "empty_check" in row]
        idle = [row for row in rows if "idle_poll" in row]
        assert len(attach) == 1 and len(checks) == 31 and checks[0]["baseline"]
        assert [row["empty_check"] for row in checks] == list(range(31))
        save({
            "history": args.history,
            "fixture": str(args.fixture) if args.fixture else None,
            "daemon_attach_nanoseconds": attach[0]["daemon_attach_nanoseconds"],
            "baseline": checks[0],
            "owner_nanoseconds": distribution([row["owner_nanoseconds"] for row in checks[1:]]),
            "wall_nanoseconds": distribution([row["wall_nanoseconds"] for row in checks[1:]]),
            "polls": distribution([row["polls"] for row in checks[1:]]),
            "database_growth_bytes": distribution([row["database_growth_bytes"] for row in checks[1:]]),
            "idle_poll_owner_nanoseconds": distribution([row["owner_nanoseconds"] for row in idle]),
            "process_seconds": elapsed,
            "load_average": os.getloadavg(),
            **retained(root),
        })
        return
    if args.mode == "empty":
        samples, elapsed = invoke("empty")
        assert len(samples) == 31 and samples[0]["baseline"]
        assert [row["empty_check"] for row in samples] == list(range(31))
        save({
            "baseline": samples[0],
            "owner_nanoseconds": distribution([row["owner_nanoseconds"] for row in samples[1:]]),
            "database_growth_bytes": distribution([row["database_growth_bytes"] for row in samples[1:]]),
            "process_seconds": elapsed,
            **retained(root),
        })
        return
    first = 1
    owner_times = []
    for target in targets:
        while first < target:
            last = min(first + 4095, target - 1)
            samples, elapsed = invoke("seed", first, last)
            assert [row["directive"] for row in samples] == list(range(first, last + 1))
            owner_times.extend(row["owner_nanoseconds"] for row in samples)
            first = last + 1
            print(json.dumps({"terminal_tasks_seeded": first, "process_seconds": elapsed}), flush=True)
        samples, elapsed = invoke("measure")
        assert len(samples) == 1 and samples[0]["terminal_tasks"] == target
        save({
            **samples[0],
            **retained(root),
            "directive_owner_nanoseconds": distribution(owner_times),
            "measurement_process_seconds": elapsed,
            "load_average": os.getloadavg(),
        })


if __name__ == "__main__":
    main()
