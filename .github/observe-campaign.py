"""Observe the retained campaign's existing clock captures until its real test exits."""
from contextlib import closing
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

def main():
    suite = Path(sys.argv[1]).resolve()
    runner = Path(__file__).with_name("measure-native-case.py")
    selected = "native experiment compares all cases and retains unknown cost through interruption"
    with subprocess.Popen([sys.executable, str(runner), str(suite), "21", selected]) as test:
        started = time.monotonic()
        last = {}
        while True:
            try:
                return test.wait(timeout=30)
            except subprocess.TimeoutExpired:
                pass
            for path in Path(".zig-cache/tmp").glob("*/native/state.sqlite"):
                try:
                    with closing(sqlite3.connect(path.resolve().as_uri()+"?mode=ro", uri=True, timeout=0)) as db:
                        rows = db.execute(
                            "SELECT rowid, substr(body,-44,12) FROM objects WHERE rowid > ? "
                            "AND length(body)=176 AND substr(body,1,8)=cast('ABL_ERQ3' AS blob) "
                            "AND instr(body,cast('paredros.experiment.clock.v1' AS blob))>0 ORDER BY rowid",
                            (last.get(path, 0),),
                        ).fetchall()
                except sqlite3.OperationalError:
                    continue
                for key, stamp in rows:
                    last[path] = key
                    fields = [int.from_bytes(stamp[n:n+4], 'little') for n in (0, 4, 8)]
                    print(f"elapsed={time.monotonic()-started:.1f} row={key} clock={fields}", flush=True)

if __name__ == "__main__":
    sys.exit(main())
