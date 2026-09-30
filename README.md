# LiteView

A tiny two-computer remote desktop tool.

- **Host** (the computer being controlled) runs `host.py`.
- **Controller** opens `http://<host-ip>:8765` in any browser. It needs nothing installed.

## Run the host

```bash
python -m venv .venv
.venv/bin/pip install -r requirements.txt      # Windows: .venv\Scripts\pip install -r requirements.txt
.venv/bin/python host.py                       # Windows: .venv\Scripts\python host.py
```

The host prints the URL and password. The password is generated once and saved in
`~/.liteview_password`, so it stays the same between runs. Override it with
`--password` or the `LITEVIEW_PASSWORD` env var.

Options: `--port`, `--fps`, `--quality`, `--max-width`, `--view-only`.

Only one controller can be connected at a time. If the connection drops, the viewer reconnects automatically.

## Supported hosts

| Host OS | Works? |
|---|---|
| Windows | Yes |
| Linux on X11 (Xorg) | Yes |
| Linux on Wayland (default on Fedora/Ubuntu GNOME) | No. Screen capture comes back black and input injection is blocked. |
| macOS | Yes, after granting Screen Recording and Accessibility permissions to the terminal/Python. |

The controller can run any OS with a modern browser.

## Start automatically ("always connectable")

- **Windows:** press Win+R, run `shell:startup`, and put a shortcut there to
  `C:\path\to\.venv\Scripts\pythonw.exe C:\path\to\host.py`.
- **Linux (X11):** add a `.desktop` file to `~/.config/autostart/` that runs the same command.

Allow TCP port 8765 through the host's firewall.

## Notes

- Built for use on a LAN. Traffic is **not encrypted**. To connect over the internet,
  use a VPN such as [Tailscale](https://tailscale.com) and connect to the host's Tailscale IP.
  Don't port-forward this to the open internet.
- Click **Fullscreen** (Chrome/Edge) to capture keys like Alt+Tab and the Windows key.
  Ctrl+Alt+Del can't be sent.
