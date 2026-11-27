#!/usr/bin/env bash
# Preview2 sockets through the `wasmtime` command entry (entry.c, as on the phone):
# TCP to a listener by address and by name, a refused closed port, and UDP.
# Usage: sockets-contract.sh LIBASHELL_P3_HOST.a WORK_DIR
set -euo pipefail
proof=$(cd "$(dirname "$0")" && pwd -P)
archive=${1:?Specify the host static library}
mkdir -p "${2:?Specify the work directory}"
work=$(cd "$2" && pwd -P)

CARGO_TARGET_DIR="$work/target" cargo build --manifest-path "$proof/sockets/Cargo.toml" \
  --locked --release --target wasm32-wasip2 -q
guest=$work/target/wasm32-wasip2/release/ashell-sockets-probe.wasm
clang -O2 -Wall -Wextra -Werror "$proof/cli.c" "$proof/entry.c" "$archive" \
  -framework Security -framework SystemConfiguration -o "$work/wasmtime"

# The listener stays in this process so its ports are known and stay bound.
python3 -I - "$work/wasmtime" "$guest" <<'PY'
import socket, subprocess, sys

command, guest = sys.argv[1:]
tcp = socket.socket()
tcp.bind(("127.0.0.1", 0))
tcp.listen(4)
# A released port is refused at once; a bound, non-listening one makes macOS drop the SYN.
probe = socket.socket()
probe.bind(("127.0.0.1", 0))
closed_port = probe.getsockname()[1]
probe.close()
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(("127.0.0.1", 0))
udp.settimeout(5)
failures = 0

def check(label, args, status, needle):
    global failures
    result = subprocess.run([command, guest, *args], capture_output=True, text=True, timeout=60)
    ok = result.returncode == status and needle in result.stdout
    failures += not ok
    print(f"{'PASS' if ok else 'FAIL'} {label}: status {result.returncode}, {result.stdout.strip()!r} {result.stderr.strip()!r}")

check("tcp listener by address", ["tcp", f"127.0.0.1:{tcp.getsockname()[1]}"], 0, "tcp ok")
check("tcp listener by name", ["tcp", f"localhost:{tcp.getsockname()[1]}"], 0, "tcp ok")
check("tcp closed port refused", ["tcp", f"127.0.0.1:{closed_port}"], 1, "ConnectionRefused")
check("udp datagram sent", ["udp", f"127.0.0.1:{udp.getsockname()[1]}"], 0, "udp ok")
try:
    data = udp.recv(16)
except OSError as error:
    data = repr(error).encode()
ok = data == b"ping"
failures += not ok
print(f"{'PASS' if ok else 'FAIL'} udp datagram received: {data!r}")
sys.exit(1 if failures else 0)
PY
