"""Run the repository's offline qualification on the current host."""

import argparse
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import stat
import subprocess
import sys
import tempfile
import time


@dataclass
class Job:
    name: str
    args: list
    needs: tuple = ()
    verify: object = None
    fixture: str = ""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def exact_line(expected):
    def verify(log):
        require(expected in log.read_text(errors="replace").splitlines(), f"missing: {expected}")
    return verify


ESSENTIAL_GROUPS = ("providers",)
BUDGET_SECONDS = 600


def set_budget(seconds):
    global BUDGET_SECONDS
    BUDGET_SECONDS = seconds


def build_jobs():
    memory = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    return max(1, min(os.cpu_count() or 1, memory // (3 << 30)))


def inventory(zig, system, install, output, full):
    linux = system == ("Linux", "x86_64")
    require(linux or system == ("Darwin", "arm64"), f"unsupported host: {system}")
    matrix = json.loads(subprocess.check_output(["node", ".github/native-execution.mjs"]))["include"]
    if not linux:
        counts = {"authority": 111, "providers": 40, "transitions": 50, "rendering": 68, "continuity": 61}
        matrix = [dict(name=name, part=name, count=n) for name, n in counts.items()] + [
            row for row in matrix if row["part"] in ("methods", "product", "crash")
        ]
    essential_parts = (*ESSENTIAL_GROUPS, "product", "crash")
    if full:
        matrix = [row for row in matrix if row["part"].partition("-")[0] in essential_parts]

    def build(*args):
        return [zig, "build", *args, "-Doptimize=safe", f"-j{build_jobs()}", "--summary", "all", "--prefix", install]

    def source_tests(log):
        require(any(line.startswith("Build Summary:") and line.endswith("; 111/111 tests passed")
                    for line in log.read_text(errors="replace").splitlines()), "expected 111 passing source tests")

    target = ["-Dtarget=x86_64-linux-musl"] if linux else []
    assets = "-Demitted-application=app/emitted"
    binary = install / "bin/paredros"
    tools = install / "test-tools"
    combined = full and not linux
    jobs = [
        Job("tigerstyle", ["bash", "tools/tiger-style.sh", "--all", "HEAD"]),
        Job("setup", build("setup")),
    ]
    if combined:
        groups = [f"-Dnative-group={group}" for group in ESSENTIAL_GROUPS]
        jobs.append(Job("build", build("check-emitted", "test", "install", "build-crash-tests",
                                       "build-native-tests", "-Dnative=true", "-Dcrash-tests=true",
                                       "-Dnative-tests=true", "-Dtest-product-assets=false", *groups,
                                       assets), ("setup",), source_tests))
    else:
        jobs.append(Job("source", build("test", "-Dnative=false"), verify=source_tests))
        jobs.append(Job("emitted", build("check-emitted", "-Dnative=true", *target, assets), ("setup",)))
    product = "build" if combined else "build-product"
    for part in dict.fromkeys(row["part"] for row in matrix):
        group, _, partition = part.partition("-")
        if part == "product":
            recipe = ["-Dnative=true", *target, assets]
        elif part == "crash":
            recipe = ["build-crash-tests", "-Dcrash-tests=true", assets]
        else:
            recipe = ["build-native-tests", "-Dnative-tests=true", f"-Dnative-group={group}"]
            if partition:
                recipe.append(f"-Dnative-partition={partition}")
            recipe.append(assets if group in ("authority", "continuity") else "-Dtest-product-assets=false")
        builder = "build" if combined else "build-" + part
        if not combined:
            jobs.append(Job(builder, build(*recipe), ("setup",)))
        for row in (item for item in matrix if item["part"] == part):
            name, count = row["name"], row["count"]
            executable = tools / "native" / part
            if part in ("product", "crash"):
                is_product = part == "product"
                report = output / (name + ".json")
                args = [sys.executable, "tests/product_smoke.py" if is_product else "tests/process_crash.py",
                        binary if is_product else tools / "paredros-crash-tests", "--report", report]
                if is_product and linux:
                    args.append("--essential")

                def verify(_, report=report, count=count, is_product=is_product):
                    data = json.loads(report.read_bytes())
                    observed = data["count"] if is_product else len(data["cases"])
                    require(observed == count and data["passed"], f"{report}: expected {count} passes")
            elif "index" in row:
                args = ["node", tools / "native/qualification_tests.mjs", executable,
                        json.dumps(row["filters"]), json.dumps([row["index"]])]
                verify = exact_line(f"{count}/{count} tests passed across 1 independent groups "
                                    f"({row['inventory']} tests in complete inventory).")
            else:
                args, verify = [executable], exact_line(f"All {count} tests passed.")
            jobs.append(Job(name, args, (builder,), verify))

    histories = [("historical-reopen", "reopen"), ("historical-import", "archive")]
    if not full:
        histories.append(("daemon-100k", "100k"))
    for name, suffix in histories:
        variable = f"PAREDROS_HISTORY_{suffix.upper()}"
        fixture = Path(os.environ.get(variable) or Path(".zig-cache/qualification-fixtures") / suffix)
        jobs.append(Job(name, [sys.executable, "tests/qualification_fixtures.py", name, binary,
                               fixture], (product,), fixture=variable))
    return jobs


def shared_deadline(started):
    pid, age = os.getppid(), 0.0
    while pid > 1:
        try:
            row = subprocess.check_output(["ps", "-p", str(pid), "-o", "ppid=,etime=,comm="], text=True).split()
        except subprocess.CalledProcessError:
            break
        if len(row) < 3 or Path(row[2]).name not in ("zig", "maker", "uv"):
            break
        clock, _, days = row[1].partition("-")[::-1] if "-" in row[1] else (row[1], "", "0")
        seconds = 0
        for part in clock.split(":"):
            seconds = seconds * 60 + int(part)
        age = int(days) * 86400 + seconds + 1
        pid = int(row[0])
    return started + BUDGET_SECONDS - age


def stop_process(process):
    # SIGINT lets the process-crash harness clean up its independently sessioned fixture.
    for sig in (signal.SIGINT, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        if sig == signal.SIGINT:
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
    process.wait()


def execute(job, logfile, deadline):
    started = time.monotonic()
    args = list(map(str, job.args))
    result = {"command": args, "log": logfile.name, "state": "failed"}
    try:
        with logfile.open("x") as log:
            process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                result["exit"] = process.wait(timeout=max(0, deadline - time.monotonic()))
            except (KeyboardInterrupt, subprocess.TimeoutExpired):
                stop_process(process)
                raise
        if result["exit"] == 0:
            if job.verify:
                job.verify(logfile)
            result["state"] = "passed"
    except subprocess.TimeoutExpired:
        result["state"] = "timed-out"
    except KeyboardInterrupt:
        result["state"] = "interrupted"
    except (OSError, ValueError, KeyError) as error:
        result["reason"] = str(error)
    if result["state"] == "passed" and time.monotonic() > deadline:
        result["state"] = "timed-out"
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    return result


def missing_fixture(job):
    if not job.fixture:
        return None
    fixture = Path(job.args[-1])
    paths = ["config.json", "report.json"]
    if job.name in ("historical-reopen", "daemon-100k"):
        paths += ["state/identity", "state/seal", "state/state.sqlite", "state/owner.lock"]
    if job.name in ("historical-reopen", "historical-import"):
        paths.append("backups/legacy-audit")
    missing = [entry for entry in paths if not (fixture / entry).is_file()]
    if missing:
        return f"{fixture} ({job.fixture}) requires: {', '.join(missing)}"
    return None


def source_identity():
    def git(*args):
        return subprocess.check_output(["git", *args])

    names = git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0")
    digest = hashlib.sha256()
    for raw in sorted(set(names) - {b""}):
        path = Path(os.fsdecode(raw))
        digest.update(raw + b"\0")
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            digest.update(b"deleted\0")
            continue
        require(stat.S_ISLNK(mode) or stat.S_ISREG(mode), f"unexpected source: {path}")
        data = os.fsencode(os.readlink(path)) if stat.S_ISLNK(mode) else path.read_bytes()
        digest.update(mode.to_bytes(4, "big") + hashlib.sha256(data).digest())
    return {"head": git("rev-parse", "HEAD").decode().strip(), "files_sha256": digest.hexdigest(),
            "dirty": bool(git("status", "--porcelain", "--untracked-files=all"))}


def product_expectations(system):
    return {"artifact_zig_backend": "stage2_x86_64" if system == "Linux" else "stage2_llvm",
            "c_family": "clang", "c_driver": "zig build-obj", "zig_version": "0.17.1"}


def select_group(jobs, names):
    if names is None:
        return jobs
    needed = set(names.split(","))
    require(all(needed), "empty qualification group name")
    for job in reversed(jobs):
        if job.name in needed:
            needed.update(job.needs)
    selected = [job for job in jobs if job.name in needed]
    require(len(selected) == len(needed), f"unknown qualification group in: {names}")
    return selected


def run(jobs, output, started, deadline, source=None, selection=None):
    rows = {job.name: {"state": "unrun"} for job in jobs}
    require(len(rows) == len(jobs), "duplicate qualification job")

    initial = source or source_identity()
    source_error = None

    def save():
        success = source_error is None and all(item["state"] == "passed" for item in rows.values())
        report = {"platform": [platform.system(), platform.machine()], "shared_budget_seconds": BUDGET_SECONDS,
                  "selected_group": selection, "qualified": selection is None and success and BUDGET_SECONDS <= 600,
                  "source": initial, "source_error": source_error,
                  "expected_product": product_expectations(platform.system()),
                  "elapsed_seconds": round(time.monotonic() - (deadline - BUDGET_SECONDS), 3), "jobs": rows,
                  "passed": success}
        temp = output / "result.tmp"
        temp.write_text(json.dumps(report, indent=2) + "\n")
        temp.replace(output / "result.json")
        return report["passed"]

    try:
        unavailable = {job.name: reason for job in jobs if (reason := missing_fixture(job))}
        if unavailable:
            for name in rows:
                rows[name]["reason"] = unavailable.get(name) or "missing prerequisites: " + ", ".join(unavailable)
            for reason in unavailable.values():
                print(reason, file=sys.stderr)
            return 1
        save()
        for job in jobs:
            if source_identity() != initial:
                source_error = f"source changed before {job.name}"
                break
            missing = [name for name in job.needs if rows[name]["state"] != "passed"]
            fixture_error = missing_fixture(job)
            if fixture_error:
                rows[job.name]["reason"] = fixture_error
            elif missing:
                rows[job.name]["reason"] = "prerequisite incomplete: " + ", ".join(missing)
            else:
                rows[job.name] = {"state": "running", "log": f"{job.name}.log"}
                save()
                print(f"Running {job.name}", flush=True)
                rows[job.name] = execute(job, output / (job.name + ".log"), deadline)
                if source_identity() != initial:
                    source_error = f"source changed during {job.name}"
                    rows[job.name].update(state="failed", reason=source_error)
                    break
            print(f"{job.name}: {rows[job.name]['state']}", flush=True)
            save()
            if rows[job.name]["state"] == "interrupted":
                return 130
    except KeyboardInterrupt:
        return 130
    finally:
        if source_error:
            print(source_error, flush=True)
        for row in rows.values():
            if row["state"] == "unrun" and source_error:
                row.setdefault("reason", source_error)
            if row["state"] == "running":
                row["state"] = "interrupted"
        passed = save()
        elapsed = time.monotonic() - (deadline - BUDGET_SECONDS)
        print(f"Elapsed {elapsed:.1f}s since zig build started (budget {BUDGET_SECONDS}s). "
              f"Report: {output / 'result.json'}", flush=True)
    return 0 if passed else 1


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zig", help="Zig compiler used by the outer build")
    options = parser.add_mutually_exclusive_group()
    options.add_argument("--list", action="store_true", help="print the local inventory without running it")
    options.add_argument("--group", help="run comma-separated groups and their prerequisites")
    parser.add_argument("--budget-seconds", type=int, default=BUDGET_SECONDS,
                        help="shared wall-clock budget measured from zig build (default 600)")
    args = parser.parse_args()
    require(0 < args.budget_seconds <= 900, "budget must be between 1 and 900 seconds")
    set_budget(args.budget_seconds)
    system = (platform.system(), platform.machine())
    base = Path("zig-out/qualification").resolve()
    install = base / ("build-" + "-".join(system))
    if args.list:
        for job in inventory(args.zig, system, install, base, full=False):
            detail = missing_fixture(job)
            if job.name == "product":
                detail = json.dumps(product_expectations(system[0]))
            print(f"{job.name}  {detail}" if detail else job.name)
        return 0
    deadline = shared_deadline(started)
    require(subprocess.check_output([args.zig, "version"], text=True).strip() == "0.17.1", "expected Zig 0.17.1")
    base.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="run-", dir=base))
    install.mkdir(exist_ok=True)
    os.environ["PYTHONOPTIMIZE"] = "0"
    if system == ("Linux", "x86_64"):
        os.environ.setdefault("ZIG_DEBUG_CMD", "1")
    # Each successful build installs current artifacts, while each run gets new logs and test results.
    with (install / ".qualification.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print(f"Qualification results: {output}", flush=True)
        initial = source_identity()
        jobs = select_group(inventory(args.zig, system, install, output, full=args.group is None), args.group)
        return run(jobs, output, started, deadline, initial, args.group)


if __name__ == "__main__":
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
