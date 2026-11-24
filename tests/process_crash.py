import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time


PHASES = (
    "control_admitted",
    "replacement_admitted",
    "read_dispatched",
    "read_captured",
    "genesis_admitted",
    "turn_admitted",
    "model_dispatched",
    "model_captured",
)


def environment(phase, path, mode, witness=None):
    result = os.environ.copy()
    result.update(
        PAREDROS_CRASH_PHASE=phase,
        PAREDROS_CRASH_PATH=str(path),
        PAREDROS_CRASH_MODE=mode,
    )
    if witness is not None:
        result["PAREDROS_CRASH_WITNESS"] = json.dumps(witness)
    return result


def cut(binary, phase, path, stderr, deadline):
    process = subprocess.Popen(
        [str(binary)],
        env=environment(phase, path, "crash"),
        stdout=subprocess.PIPE,
        stderr=stderr,
        start_new_session=True,
    )
    events = []
    pending = b""
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                if not selector.select(min(1, max(0, deadline - time.monotonic()))):
                    continue
                data = os.read(process.stdout.fileno(), 4096)
                if not data:
                    raise RuntimeError(f"{phase}: child exited before injection boundary")
                pending += data
                if len(pending) > 1024 * 1024:
                    raise RuntimeError(f"{phase}: unbounded fixture output")
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    event = json.loads(line)
                    events.append(event)
                    if event.get("cut") == phase:
                        os.killpg(process.pid, signal.SIGKILL)
                        status = process.wait(timeout=5)
                        if status != -signal.SIGKILL:
                            raise RuntimeError(f"{phase}: expected SIGKILL, got {status}")
                        return event["witness"], events
            raise TimeoutError(f"{phase}: injection boundary deadline")
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        process.stdout.close()


def verify(binary, phase, path, witness, deadline):
    result = subprocess.run(
        [str(binary)],
        env=environment(phase, path, "verify", witness),
        capture_output=True,
        text=True,
        timeout=max(0.01, deadline - time.monotonic()),
    )
    if result.returncode:
        raise RuntimeError(f"{phase}: verification failed\n{result.stderr}\n{result.stdout}")
    events = [json.loads(line) for line in result.stdout.splitlines()]
    terminal = [event for event in events if event.get("verified") == phase]
    if len(terminal) != 1:
        raise RuntimeError(f"{phase}: missing unique verification result")
    calls = [event for event in events if "acquired" in event]
    expected = 1 if phase in ("read_dispatched", "turn_admitted", "model_dispatched") else 0
    if len(calls) != expected or terminal[0]["acquisitions"] != expected:
        raise RuntimeError(f"{phase}: unexpected external acquisition count")
    if phase != "turn_admitted" and any(
        event["task"] == witness["subject"] for event in calls
    ):
        raise RuntimeError(f"{phase}: original acquisition repeated")
    return events


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    binary_digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    started = time.monotonic()
    deadline = started + 600
    results = []
    with tempfile.TemporaryDirectory(prefix="paredros-process-crash-") as directory:
        root = Path(directory).resolve(strict=True)
        for phase in PHASES:
            path = root / phase / "namespace"
            path.parent.mkdir(mode=0o700)
            before = time.monotonic()
            with (root / f"{phase}.stderr").open("wb") as log:
                try:
                    witness, original = cut(binary, phase, path, log, deadline)
                except Exception as error:
                    detail = (root / f"{phase}.stderr").read_text(errors="replace")[-16_384:]
                    raise RuntimeError(f"{phase}: {error}\n{detail}") from error
            calls = [event for event in original if "acquired" in event]
            expected = 1 if phase in (
                "read_dispatched", "read_captured", "model_dispatched", "model_captured"
            ) else 0
            if len(calls) != expected:
                raise RuntimeError(f"{phase}: injection missed the external call boundary")
            restored = verify(binary, phase, path, witness, deadline)
            row = {
                "phase": phase,
                "termination": "SIGKILL",
                "witness": witness,
                "original_events": original,
                "restored_events": restored,
                "seconds": time.monotonic() - before,
                "namespace_bytes": sum(p.stat().st_size for p in path.rglob("*") if p.is_file()),
            }
            results.append(row)
            print(json.dumps(row), flush=True)
    report = {
        "passed": True,
        "binary_sha256": binary_digest,
        "platform": platform.platform(),
        "live_services": False,
        "seconds": time.monotonic() - started,
        "cases": results,
    }
    if hashlib.sha256(binary.read_bytes()).hexdigest() != binary_digest:
        raise RuntimeError("fixture binary changed during execution")
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
