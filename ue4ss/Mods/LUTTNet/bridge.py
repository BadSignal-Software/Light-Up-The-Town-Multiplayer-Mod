#!/usr/bin/env python3
"""
LUTTNet bridge - moves lines between luttnet_out.txt / luttnet_in.txt and a TCP peer.

Put this file in Mods\\LUTTNet\\ (next to the Scripts folder); it reads/writes its files in its own folder.

  python bridge.py mirror              solo test: reflects your own changes back, shifted 500 units on X
  python bridge.py host 7777           wait for a friend to connect
  python bridge.py join 100.x.y.z 7777 connect to a friend's host

Start the game and load into a level FIRST, then start the bridge.
No authentication or encryption: only use over a VPN (Tailscale/ZeroTier) or with someone you trust.
"""
import os
import socket
import sys
import threading
import time

OUT = "luttnet_out.txt"
IN = "luttnet_in.txt"
MIRROR_DX = 500.0

# Use the bridge's own folder, so it must sit in Mods/LUTTNet/ next to the mod's files.
os.chdir(os.path.dirname(os.path.abspath(__file__)))
lock = threading.Lock()


def write_in(lines):
    if not lines:
        return
    with lock, open(IN, "ab") as f:
        f.write(("\n".join(lines) + "\n").encode())


def read_new_out(state):
    """Return complete new lines from OUT since last call."""
    try:
        size = os.path.getsize(OUT)
    except OSError:
        return []
    if size < state["off"]:
        state["off"] = 0
    if size == state["off"]:
        return []
    with open(OUT, "rb") as f:
        f.seek(state["off"])
        data = f.read(size - state["off"])
    cut = data.rfind(b"\n")
    if cut < 0:
        return []
    state["off"] += cut + 1
    return [l.decode(errors="replace").rstrip("\r") for l in data[: cut + 1].split(b"\n") if l]


def shift_guid(g):
    p = g.split(":")
    if len(p) != 4 or g == "0:0:0:0":
        return g
    p[0] = str(int(p[0]) + 1)
    return ":".join(p)


def mirror_line(line):
    f = line.split("\t")
    k = f[0]
    try:
        if k == "U" and len(f) >= 19:
            f[1] = shift_guid(f[1])
            f[7] = "%.3f" % (float(f[7]) + MIRROR_DX)    # translation X
            f[13] = "%.3f" % (float(f[13]) + MIRROR_DX)  # end location X
            f[17] = shift_guid(f[17])                    # parent guid
            return "\t".join(f)
        if k == "D" and len(f) >= 2:
            f[1] = shift_guid(f[1])
            return "\t".join(f)
        if k == "P" and len(f) >= 5:
            f[1] = "%.1f" % (float(f[1]) + MIRROR_DX)
            return "\t".join(f)
    except ValueError:
        pass
    return None


def fresh_files():
    open(OUT, "wb").close()
    open(IN, "wb").close()


def run_mirror():
    fresh_files()
    state = {"off": 0}
    write_in(["HELLO"])
    print("mirror mode: place/delete decorations and walk around; copies appear %d units to the +X side. Ctrl+C to stop." % MIRROR_DX)
    try:
        while True:
            out = [m for m in (mirror_line(l) for l in read_new_out(state)) if m]
            write_in(out)
            time.sleep(0.03)
    except KeyboardInterrupt:
        write_in(["BYE"])


def pump_out(sock, stop):
    state = {"off": 0}
    while not stop.is_set():
        lines = read_new_out(state)
        if lines:
            try:
                sock.sendall(("\n".join(lines) + "\n").encode())
            except OSError:
                stop.set()
                return
        time.sleep(0.03)


def pump_in(sock, stop):
    buf = b""
    sock.settimeout(0.5)
    while not stop.is_set():
        try:
            data = sock.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            break
        if not data:
            break
        buf += data
        cut = buf.rfind(b"\n")
        if cut >= 0:
            chunk, buf = buf[: cut + 1], buf[cut + 1:]
            write_in([l.decode(errors="replace").rstrip("\r") for l in chunk.split(b"\n") if l])
    stop.set()


def run_session(sock):
    fresh_files()
    stop = threading.Event()
    write_in(["HELLO"])
    threading.Thread(target=pump_out, args=(sock, stop), daemon=True).start()
    print("connected. Ctrl+C to stop.")
    try:
        pump_in(sock, stop)
    except KeyboardInterrupt:
        pass
    stop.set()
    write_in(["BYE"])
    sock.close()
    print("disconnected.")


def main():
    print("using files in:", os.getcwd())
    if len(sys.argv) < 2:
        print(__doc__)
        return
    mode = sys.argv[1]
    if mode == "mirror":
        run_mirror()
    elif mode == "host":
        port = int(sys.argv[2]) if len(sys.argv) > 2 else 7777
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", port))
        srv.listen(1)
        print("listening on port %d ..." % port)
        conn, addr = srv.accept()
        print("peer:", addr)
        run_session(conn)
    elif mode == "join":
        host = sys.argv[2]
        port = int(sys.argv[3]) if len(sys.argv) > 3 else 7777
        s = socket.create_connection((host, port), timeout=10)
        run_session(s)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
