import os
from pathlib import Path
import shlex
import shutil
import subprocess

out = Path("compiler-comparison")
out.mkdir()
lines = Path("compile.log").read_text().splitlines()
commands = [line.split("info(verbose): ", 1)[1] for line in lines
            if "info(verbose): " in line and "zig test " in line and "-Mroot=native_methods_test.zig" in line]
assert len(commands) == 1
command = shlex.split(commands[0])
lib = next(Path(arg.split("=", 1)[1]).parents[2]
           for arg in command if arg.startswith("-Mprotean_native="))
archive, = [Path(arg) for arg in command if arg.endswith("/libprotean-native-c.a")]
names = "open openat pread unlinkat poll pwrite kill linkat read write readv writev pipe socketpair fchmodat".split()
(out / "aliases").write_text("\n".join(names) + "\n")
zig = command[0]
with (out / "native_c.zig").open("wb") as binding:
    subprocess.run([zig, "translate-c", "-lc", "-target", "x86_64-linux-musl",
                    "-I", ".protean-native/inputs/sqlite",
                    *[f"-D{name}=protean_posix_{name}" for name in names],
                    str(lib / "runtime/native/native_c.h")], stdout=binding, check=True)
args = [f"-Mnative_c={out}/native_c.zig" if arg.startswith("-Mnative_c=") else arg
        for arg in command[2:] if arg != "--listen=-" and arg != str(archive)]
subprocess.run([zig, "test", "-ofmt=c", *args, "--test-no-exec",
                f"-femit-bin={out}/methods.c"], check=True)
ziglib = Path(os.path.realpath(zig)).parent / "lib"
subprocess.run([zig, "build-obj", "-ofmt=c", "-fno-llvm", "-Osmall",
                "-target", "x86_64-linux-musl", str(ziglib / "compiler_rt.zig"),
                f"-femit-bin={out}/compiler-rt.c"], check=True)
with (out / "zig.h").open("wb") as header:
    subprocess.run(["awk", "-f", ".github/zig-0.17.1-header.awk", str(ziglib / "zig.h")], stdout=header, check=True)
shutil.copy(archive, out / "libprotean-native-c.a")
