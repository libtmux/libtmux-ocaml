#!/usr/bin/python3
"""Fault only the short-lived read process; control connections use real tmux."""
import os
import socket
import subprocess
import sys

binary = os.environ["LIBTMUX_TEST_BINARY"]
arguments = sys.argv[1:]
if "show-environment" not in arguments:
    os.execv(binary, [binary, *arguments])

result = subprocess.run([binary, *arguments], capture_output=True, timeout=1)
output = result.stdout
mode = os.environ["LIBTMUX_TEST_READ_MODE"]
if mode == "truncated":
    output = output.rsplit(b"\n", 2)[0] + b"\n"
elif mode == "malformed":
    prefix = output.split(b"\n", 1)[0] + b"\n"
    output = prefix + b'A="x"; export B;\n' + arguments[-1].encode() + b"\n"
elif mode == "oversized":
    output = b"X" * (4 * 1024 * 1024 + 1)
elif mode == "error":
    sys.stderr.buffer.write(b"injected read failure\n")
elif mode == "cancel":
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as barrier:
        barrier.connect(os.environ["LIBTMUX_TEST_BARRIER"])
        barrier.sendall(b"HELD\n")
        assert barrier.recv(1) == b"G"
sys.stdout.buffer.write(output)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
