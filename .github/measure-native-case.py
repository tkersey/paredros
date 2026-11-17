"""Time one named test in an existing Zig 0.17.1 test executable."""
import argparse
import struct
import subprocess
import time


def frame(process, tag, body=b''):
    process.stdin.write(struct.pack('<II', tag, len(body)) + body)
    process.stdin.flush()


def receive(process, expected):
    tag, length = struct.unpack('<II', process.stdout.read(8))
    if tag != expected:
        raise ValueError(f'Expected response {expected}, got {tag}')
    body = process.stdout.read(length)
    if len(body) != length:
        raise EOFError('Incomplete test runner response')
    return body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary')
    parser.add_argument('count', type=int)
    parser.add_argument('suffix')
    args = parser.parse_args()
    with subprocess.Popen([args.binary, '--listen=-'], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE) as process:
        try:
            assert receive(process, 0) == b'0.17.1'
            frame(process, 4)
            metadata = receive(process, 3)
            size, count = struct.unpack_from('<II', metadata)
            assert count == args.count and len(metadata) == 8 + count * 8 + size
            strings = metadata[8 + count * 8:]
            offsets = struct.unpack_from(f'<{count}I', metadata, 8)
            names = [strings[offset:strings.index(0, offset)].decode() for offset in offsets]
            matches = [i for i, name in enumerate(names) if name.endswith(args.suffix)]
            if len(matches) != 1:
                raise ValueError(f'Expected one match for {args.suffix}: {matches}')
            index = matches[0]
            frame(process, 5, struct.pack('<I', index))
            assert receive(process, 5) == b''
            print(f'Starting {index + 1}/{count} {names[index]}', flush=True)
            start = time.monotonic()
            actual, flags = struct.unpack('<IQ', receive(process, 4))
            print(f'Finished {names[index]} after {time.monotonic()-start:.3f}s, flags={flags}', flush=True)
            assert actual == index and flags == 0, 'test failed, skipped, leaked, or logged errors'
            frame(process, 0)
            assert process.wait(timeout=5) == 0
        finally:
            if process.poll() is None:
                process.kill()


if __name__ == '__main__':
    main()
