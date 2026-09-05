#!/usr/bin/env python3
"""Sector server for the PS1-in-Roblox front-end.

Roblox cannot read local files, so the emulator fetches BIOS + disc sectors
over HTTP.  This server exposes a raw PS1 disc image (.bin, 2352-byte
sectors) plus an optional BIOS ROM to the Roblox scripts in
src/server/PS1Runtime.server.luau.

Endpoints (all text/plain; sectors and BIOS are base64-encoded):

    GET /info             total sector count of the disc
    GET /sector/<lba>     one raw 2352-byte sector, base64
    GET /bios             the BIOS ROM bytes, base64
    GET /checkpoints      newline-separated list of checkpoint files
    GET /checkpoint/<name>  checkpoint bytes, base64 (name is a bare filename)
    GET /health           "ok"

Usage:

    python tools/disc_server.py SLUS-0707.BIN --bios SCPH1001.BIN
    python tools/disc_server.py SLUS-0707.CUE --bios SCPH1001.BIN --port 8080
    python tools/disc_server.py SLUS-0707.BIN --bios SCPH1001.BIN --checkpoints-dir checkpoints

A .cue argument is resolved to its first FILE (single-bin discs only).
Checkpoints let the Roblox runtime skip the slow cold boot. If present, files
in the checkpoints directory are served as opaque snapshot data.
"""

import argparse
import base64
import os
import re
import socket
import sys
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECTOR_SIZE = 2352

_SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]+$")

_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>PS1 disc server</title></head>
<body style="font-family:monospace;background:#111;color:#9f9">
<h2>PS1 disc server</h2>
<ul>
<li><a href="/info">/info</a> &mdash; sector count</li>
<li><a href="/sector/16">/sector/16</a> &mdash; sample sector (base64)</li>
<li><a href="/bios">/bios</a> &mdash; BIOS ROM (base64)</li>
<li><a href="/checkpoints">/checkpoints</a> &mdash; checkpoint list</li>
</ul>
</body></html>"""


def port_already_listening(host, port):
    """True if anything is actually accepting on host:port.

    ThreadingHTTPServer sets SO_REUSEADDR, which on Windows lets several
    processes bind the same port silently; the OS then hands each incoming
    connection to an arbitrary one of them, so a stale instance running
    different code answers some of a client's requests.  Refuse to start
    instead of joining the pile.
    """
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.settimeout(0.5)
    try:
        probe.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def resolve_disc_bin(path):
    """Resolve a .bin or the first FILE entry in a single-file .cue."""
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        sys.exit(f"error: no such file: {path}")
    if path.lower().endswith(".cue"):
        cuesheet = open(path, "r", encoding="utf-8", errors="replace").read()
        matches = re.findall(r'FILE\s+"([^"]+)"\s+BINARY', cuesheet, re.IGNORECASE)
        if not matches:
            sys.exit(f"error: could not parse a FILE ... BINARY entry from {path}")
        bin_name = matches[0]
        bin_path = os.path.join(os.path.dirname(path), bin_name)
        if not os.path.isfile(bin_path):
            sys.exit(f"error: referenced bin not found: {bin_path}")
        if len(matches) > 1:
            print(f"warning: multi-file cuesheet; serving only first bin ({bin_name})")
        return bin_path
    return path


def build_server(disc_path, bios_path, checkpoints_dir, host="127.0.0.1", port=8080):
    disc_path = Path(disc_path).resolve()
    checkpoints_dir = Path(checkpoints_dir).resolve() if checkpoints_dir else None
    disc_size = disc_path.stat().st_size
    if disc_size % SECTOR_SIZE:
        print(f"warning: disc size is not a multiple of {SECTOR_SIZE}; trailing bytes will be ignored")
    sector_count = disc_size // SECTOR_SIZE
    bios_data = None
    if bios_path:
        with open(bios_path, "rb") as f:
            bios_data = f.read()
        print(f"bios: {bios_path} ({len(bios_data)} bytes)")
    print(f"disc: {disc_path} ({disc_size} bytes, {sector_count} sectors of {SECTOR_SIZE})")
    if checkpoints_dir:
        checkpoints_dir.mkdir(parents=True, exist_ok=True)
        print(f"checkpoints: {checkpoints_dir} (optional; used for fast resume)")

    def read_sector(lba):
        if lba < 0 or lba >= sector_count:
            return None
        with disc_path.open("rb") as f:
            f.seek(lba * SECTOR_SIZE)
            return f.read(SECTOR_SIZE)

    def read_checkpoint(name):
        if not _SAFE_NAME.match(name or ""):
            return None
        if not checkpoints_dir:
            return None
        # checkpoints_dir is a pathlib.Path; os.path.join would flatten it to a str
        # and then .is_file()/.open() would AttributeError -> every checkpoint fetch 500s.
        path = checkpoints_dir / name
        if not path.is_file():
            return None
        with path.open("rb") as f:
            return f.read()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # one line per request so a roblox session is auditable
            detail = " ".join(str(a) for a in args)
            print(f"[disc-server] {self.command} {self.path} -> {detail}", flush=True)

        def _send(self, body, content_type="text/plain; charset=utf-8"):
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?")[0]
            try:
                if path == "/" or path == "/index.html":
                    self._send(_PAGE.encode("utf-8"), "text/html; charset=utf-8")
                elif path == "/health":
                    self._send(b"ok")
                elif path == "/info":
                    self._send(str(sector_count).encode("ascii"))
                elif path == "/bios":
                    if bios_data is None:
                        self._send(b"no bios configured", "text/plain")
                    else:
                        self._send(base64.b64encode(bios_data))
                elif path.startswith("/sector/"):
                    raw = path[len("/sector/"):]
                    lba = int(raw)
                    sector = read_sector(lba)
                    if sector is None:
                        self.send_error(404, f"sector {lba} out of range")
                        return
                    self._send(base64.b64encode(sector))
                elif path == "/checkpoints":
                    if not checkpoints_dir:
                        self._send(b"")
                    else:
                        names = sorted(p.name for p in checkpoints_dir.iterdir())
                        names = [n for n in names if _SAFE_NAME.match(n) and (checkpoints_dir / n).is_file()]
                        self._send("\n".join(names).encode("utf-8"))
                elif path.startswith("/checkpoint/"):
                    name = path[len("/checkpoint/"):]
                    data = read_checkpoint(name)
                    if data is None:
                        self.send_error(404, f"checkpoint {name} not found")
                        return
                    self._send(base64.b64encode(data))
                else:
                    self.send_error(404, "not found")
            except (ValueError, TypeError):
                self.send_error(400, "bad request")
            except Exception as exc:  # keep the server alive on client errors
                try:
                    self.send_error(500, str(exc))
                except Exception:
                    pass

    return ThreadingHTTPServer((host, port), Handler)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Serve PS1 disc sectors + BIOS over HTTP for Roblox")
    parser.add_argument("disc", help="path to .bin (or .cue) disc image")
    parser.add_argument("--bios", default=None, help="path to PS1 BIOS ROM (default: none)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--checkpoints-dir", default="checkpoints", help="directory holding resume checkpoints (default: checkpoints)")
    args = parser.parse_args()

    if port_already_listening(args.host, args.port):
        sys.exit(
            f"error: {args.host}:{args.port} already has a listener; another disc_server is running.\n"
            "stop it first (e.g. Task Manager / netstat -ano | findstr :8080), then start this one."
        )

    bin_path = resolve_disc_bin(args.disc)
    server = build_server(bin_path, args.bios, args.checkpoints_dir, args.host, args.port)
    print(f"serving on http://{args.host}:{args.port}  (Ctrl+C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
