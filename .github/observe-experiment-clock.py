"""Sample the existing ERQ3 clock requests during an unchanged comparison."""
from pathlib import Path
import json
import sqlite3
import struct
import subprocess
import sys
import time


def clocks(path):
    with sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=1) as db:
        rows = db.execute("""
            SELECT substr(body, -44, 12) FROM objects
            WHERE length(body)=176 AND substr(body, 1, 8)=cast('ABL_ERQ3' AS blob)
              AND instr(body, cast('paredros.experiment.clock.v1' AS blob))>0
        """)
        return [struct.unpack('<III', row[0]) for row in rows]


with subprocess.Popen([sys.argv[1]]) as process:
    try:
        started = time.monotonic()
        for _ in range(18):
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                pass
            for path in Path('.zig-cache/tmp').glob('*/native/state.sqlite'):
                try:
                    stamps = clocks(path)
                except sqlite3.OperationalError:
                    continue
                print(json.dumps({'elapsed': round(time.monotonic()-started), 'stamps': stamps}), flush=True)
            info = Path(f'/proc/{process.pid}/stat')
            if info.exists():
                parts = info.read_text().split(') ')[1].split()
                print(f'CPU ticks user={parts[11]} kernel={parts[12]}', flush=True)
            if process.poll() is not None:
                sys.exit(process.returncode)
        print('Diagnostic observation window ended', flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=8)
