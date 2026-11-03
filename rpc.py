#!/usr/bin/env python3
"""Client for the launcher's main-thread Lua RPC server.

One Lua chunk per connection, framed by shutdown(SHUT_WR).

There is no authentication and no transport security: every connection gets
arbitrary Lua execution inside the title.

Usage:
  rpc.py <ip> 'return 2+2'
  rpc.py <ip> --file chunk.lua
"""
from __future__ import annotations

import argparse
import socket
import sys
from pathlib import Path

DEFAULT_PORT = 9026


def send(host: str, port: int, payload: bytes, timeout: float = 15.0) -> bytes:
    with socket.create_connection((host, port), timeout=timeout) as s:
        s.sendall(payload)
        s.shutdown(socket.SHUT_WR)          # this is the request terminator
        chunks = []
        while True:
            try:
                b = s.recv(65536)
            except socket.timeout:
                break
            if not b:
                break
            chunks.append(b)
    return b"".join(chunks)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host")
    ap.add_argument("request", nargs="*", help="command or Lua chunk")
    ap.add_argument("-p", "--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--file", type=Path, help="send this file's contents as the request")
    ap.add_argument("--restart", action="store_true",
                    help="ask the title to restart so uploaded files are re-read")
    ap.add_argument("-t", "--timeout", type=float, default=15.0)
    args = ap.parse_args()

    def do(payload: bytes) -> bytes:
        out = send(args.host, args.port, payload, args.timeout)
        return out

    if args.restart:
        sys.stdout.write(do(b'love.event.quit("restart"); return "restarting"')
                         .decode("utf-8", "replace"))
        return 0

    if args.file:
        payload = args.file.read_bytes()
    elif args.request:
        payload = " ".join(args.request).encode()
    else:
        payload = sys.stdin.buffer.read()

    sys.stdout.write(do(payload).decode("utf-8", "replace"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
