#!/usr/bin/env python3
"""LiteView host - run this on the computer you want to control.

The controlling computer just opens http://<this-computer-ip>:<port> in a browser.
"""
import argparse
import asyncio
import hashlib
import hmac
import io
import ipaddress
import json
import os
import secrets
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import mss  # import before pynput: on Windows mss makes the process DPI-aware
from aiohttp import WSMsgType, web
from PIL import Image
from pynput.keyboard import Controller as KeyboardController
from pynput.keyboard import Key, KeyCode
from pynput.mouse import Button
from pynput.mouse import Controller as MouseController

HERE = Path(__file__).resolve().parent
PASSWORD_FILE = Path.home() / ".liteview_password"
MSS = getattr(mss, "MSS", None) or mss.mss  # mss >= 10 renamed the class

# ---------------------------------------------------------------- screen capture

_capture = threading.local()  # mss handles are not thread-safe; keep one per thread


def grab_jpeg(max_width, quality, force):
    """Return the screen as JPEG bytes, or None if nothing changed since last grab."""
    if not hasattr(_capture, "sct"):
        _capture.sct = MSS()
        _capture.last_digest = None
    shot = _capture.sct.grab(_capture.sct.monitors[1])
    digest = hashlib.blake2b(shot.bgra, digest_size=16).digest()
    if digest == _capture.last_digest and not force:
        return None
    _capture.last_digest = digest

    img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
    if img.width > max_width:
        img = img.resize((max_width, round(img.height * max_width / img.width)), Image.BILINEAR)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


# ---------------------------------------------------------------- input injection

# Browser KeyboardEvent.code -> pynput Key name. Looked up with getattr because
# some keys (insert, menu, print_screen) don't exist on every OS.
SPECIAL_CODES = {
    "Enter": "enter", "NumpadEnter": "enter", "Backspace": "backspace", "Tab": "tab",
    "Escape": "esc", "Space": "space", "CapsLock": "caps_lock",
    "ArrowUp": "up", "ArrowDown": "down", "ArrowLeft": "left", "ArrowRight": "right",
    "Delete": "delete", "Insert": "insert", "Home": "home", "End": "end",
    "PageUp": "page_up", "PageDown": "page_down",
    "ShiftLeft": "shift_l", "ShiftRight": "shift_r",
    "ControlLeft": "ctrl_l", "ControlRight": "ctrl_r",
    "AltLeft": "alt_l", "AltRight": "alt_r",
    "MetaLeft": "cmd_l", "MetaRight": "cmd_r",
    "ContextMenu": "menu", "PrintScreen": "print_screen",
    **{f"F{i}": f"f{i}" for i in range(1, 13)},
}
CHAR_CODES = {
    "Minus": "-", "Equal": "=", "BracketLeft": "[", "BracketRight": "]",
    "Backslash": "\\", "Semicolon": ";", "Quote": "'", "Backquote": "`",
    "Comma": ",", "Period": ".", "Slash": "/",
    "NumpadAdd": "+", "NumpadSubtract": "-", "NumpadMultiply": "*",
    "NumpadDivide": "/", "NumpadDecimal": ".",
}
BUTTONS = {0: Button.left, 1: Button.middle, 2: Button.right}


def code_to_key(code):
    # Using physical key codes (not typed characters) means held modifiers like
    # Shift/Ctrl are applied by the host OS, so presses and releases always match.
    if code in SPECIAL_CODES:
        return getattr(Key, SPECIAL_CODES[code], None)
    if code in CHAR_CODES:
        return KeyCode.from_char(CHAR_CODES[code])
    if code.startswith("Key") and len(code) == 4:
        return KeyCode.from_char(code[3].lower())
    if code.startswith("Digit"):
        return KeyCode.from_char(code[5:])
    if code.startswith("Numpad") and code[6:].isdigit():
        return KeyCode.from_char(code[6:])
    return None


class InputInjector:
    def __init__(self, monitor):
        self.monitor = monitor
        self.mouse = MouseController()
        self.keyboard = KeyboardController()
        self.held_keys = set()
        self.held_buttons = set()

    def _move(self, ev):
        m = self.monitor
        x = min(max(float(ev["x"]), 0.0), 1.0)
        y = min(max(float(ev["y"]), 0.0), 1.0)
        self.mouse.position = (m["left"] + round(x * (m["width"] - 1)),
                               m["top"] + round(y * (m["height"] - 1)))

    def handle(self, ev):
        t = ev.get("t")
        if t == "move":
            self._move(ev)
        elif t in ("down", "up"):
            button = BUTTONS.get(ev.get("b"))
            if button is None:
                return
            self._move(ev)
            if t == "down":
                self.mouse.press(button)
                self.held_buttons.add(button)
            else:
                self.mouse.release(button)
                self.held_buttons.discard(button)
        elif t == "wheel":
            self.mouse.scroll(int(ev.get("dx", 0)), int(ev.get("dy", 0)))
        elif t in ("kd", "ku"):
            key = code_to_key(str(ev.get("code", "")))
            if key is None:
                return
            if t == "kd":
                self.keyboard.press(key)
                self.held_keys.add(key)
            else:
                self.keyboard.release(key)
                self.held_keys.discard(key)
        elif t == "releaseall":
            self.release_all()

    def release_all(self):
        """Avoid stuck keys/buttons when the viewer loses focus or disconnects."""
        for key in list(self.held_keys):
            try:
                self.keyboard.release(key)
            except Exception:
                pass
        for button in list(self.held_buttons):
            try:
                self.mouse.release(button)
            except Exception:
                pass
        self.held_keys.clear()
        self.held_buttons.clear()


# ---------------------------------------------------------------- web server

async def index(request):
    return web.FileResponse(HERE / "viewer.html")


async def stream_frames(ws, app, acked):
    loop = asyncio.get_running_loop()
    interval = 1 / app["fps"]
    force = True
    while not ws.closed:
        started = loop.time()
        jpeg = await loop.run_in_executor(
            app["capture_pool"], grab_jpeg, app["max_width"], app["quality"], force)
        if jpeg:
            force = False
            acked.clear()
            await ws.send_bytes(jpeg)
            # Wait until the viewer has drawn the frame, so a slow network
            # drops frames instead of building up seconds of lag.
            try:
                await asyncio.wait_for(acked.wait(), timeout=5)
            except asyncio.TimeoutError:
                force = True
        await asyncio.sleep(max(0.0, interval - (loop.time() - started)))


async def ws_handler(request):
    app = request.app
    peer = request.remote
    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=64 * 1024)
    await ws.prepare(request)

    try:
        first = await ws.receive(timeout=30)
        auth = json.loads(first.data) if first.type == WSMsgType.TEXT else {}
    except (asyncio.TimeoutError, ValueError):
        auth = {}
    if not hmac.compare_digest(str(auth.get("pw", "")).encode(), app["password"].encode()):
        print(f"[!] Rejected {peer}: wrong password")
        await asyncio.sleep(1)  # slow down password guessing
        await ws.send_str(json.dumps({"t": "error", "msg": "Wrong password"}))
        await ws.close(code=4001)
        return ws
    if app["session"]["busy"]:
        await ws.send_str(json.dumps({"t": "error", "msg": "Someone else is already connected"}))
        await ws.close(code=4002)
        return ws

    app["session"]["busy"] = True
    print(f"[+] {peer} connected")
    await ws.send_str(json.dumps({"t": "ok"}))
    acked = asyncio.Event()
    injector = app["injector"]
    streamer = asyncio.create_task(stream_frames(ws, app, acked))
    try:
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            try:
                ev = json.loads(msg.data)
                if ev.get("t") == "ack":
                    acked.set()
                elif not app["view_only"]:
                    injector.handle(ev)
            except Exception as exc:
                print(f"[!] Bad input event {msg.data[:80]!r}: {exc}")
    finally:
        streamer.cancel()
        injector.release_all()
        app["session"]["busy"] = False
        print(f"[-] {peer} disconnected")
    return ws


def load_password(cli_password):
    if cli_password:
        return cli_password
    if os.environ.get("LITEVIEW_PASSWORD"):
        return os.environ["LITEVIEW_PASSWORD"]
    if PASSWORD_FILE.exists():
        return PASSWORD_FILE.read_text().strip()
    password = secrets.token_urlsafe(9)
    PASSWORD_FILE.write_text(password + "\n")
    try:
        PASSWORD_FILE.chmod(0o600)
    except OSError:
        pass
    return password


def lan_ip():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("10.255.255.255", 1))  # no packet is sent; just picks the LAN interface
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"


TAILSCALE_NET = ipaddress.ip_network("100.64.0.0/10")


def tailscale_ip():
    """This computer's Tailscale IPv4 address, or None if Tailscale isn't connected."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("100.100.100.100", 1))  # Tailscale's own resolver; routes via the tailnet
            ip = s.getsockname()[0]
        except OSError:
            return None
    return ip if ipaddress.ip_address(ip) in TAILSCALE_NET else None


def wait_for_tailscale():
    # When started at boot, Tailscale may not be connected yet.
    ip = tailscale_ip()
    if ip is None:
        print("Waiting for Tailscale to connect...", flush=True)
    while ip is None:
        time.sleep(5)
        ip = tailscale_ip()
    return ip


def main():
    parser = argparse.ArgumentParser(description="LiteView host: share this screen and allow remote control.")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--password", help=f"access password (default: $LITEVIEW_PASSWORD, else saved in {PASSWORD_FILE})")
    parser.add_argument("--fps", type=float, default=15)
    parser.add_argument("--quality", type=int, default=60, help="JPEG quality 1-95 (lower = less bandwidth)")
    parser.add_argument("--max-width", type=int, default=1600, help="downscale frames wider than this")
    parser.add_argument("--view-only", action="store_true", help="share the screen but ignore mouse/keyboard")
    parser.add_argument("--tailscale-only", action="store_true",
                        help="only accept connections through Tailscale (waits for Tailscale if it isn't up yet)")
    args = parser.parse_args()

    with MSS() as sct:
        monitor = dict(sct.monitors[1])

    app = web.Application()
    app.update(
        password=load_password(args.password), fps=args.fps, quality=args.quality,
        max_width=args.max_width, view_only=args.view_only, session={"busy": False},
        injector=InputInjector(monitor),
        capture_pool=ThreadPoolExecutor(max_workers=1, thread_name_prefix="capture"),
    )
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)

    if args.tailscale_only:
        ts_ip = wait_for_tailscale()
        bind_host = ts_ip
    else:
        ts_ip = tailscale_ip()
        bind_host = "0.0.0.0"

    print("LiteView host is running.")
    if ts_ip:
        print(f"  From anywhere (Tailscale):   http://{ts_ip}:{args.port}")
    else:
        print("  Tailscale not connected - only reachable on this local network.")
    if not args.tailscale_only:
        print(f"  From the same network:       http://{lan_ip()}:{args.port}")
    print(f"  Password:                    {app['password']}")
    print(f"  Screen:                      {monitor['width']}x{monitor['height']}"
          + ("  (view only)" if args.view_only else ""))
    web.run_app(app, host=bind_host, port=args.port, print=None)


if __name__ == "__main__":
    main()
