#!/usr/bin/env python3
"""PaneCast — TV'de eşleşme kodunu ekranda tutan yoklama (cihaz testi yardımcısı).

Neden: alıcı 6 haneli kodu yalnız bir yayıncı `pair_required` isterken **ve o bağlantı açıkken**
gösteriyor; kodu okumak için ekran görüntüsü alabilmemiz lazım. Release derlemesi kodu loglamıyor
(bilinçli, docs/protocol.md §3.3), bu yüzden tek yol ekrandan okumak.

Bu betik bir bağlantıyı `--hold` saniye açık tutar; dışarıdan `adb exec-out screencap` alınır.
Anahtar üretmez, eşleşmeyi tamamlamaz, hiçbir şey yazmaz.

Kullanım: scripts/tv-pin-hold.py [TV_IP] [--hold 25]
"""
from __future__ import annotations

import base64
import json
import os
import socket
import sys
import time

MAX_LINE = 8192


def target() -> str | None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if args:
        return args[0]
    return os.environ.get("TV_IP")


def hold_seconds() -> int:
    for i, a in enumerate(sys.argv[1:]):
        if a == "--hold" and i + 2 <= len(sys.argv[1:]):
            try:
                return int(sys.argv[2 + i])
            except ValueError:
                pass
    return 25


def main() -> int:
    ip = target()
    if not ip:
        print("TV_IP ver ya da scripts/env.local.sh kullan")
        return 2
    device_id = base64.urlsafe_b64encode(os.urandom(12)).decode().rstrip("=")
    s = socket.create_connection((ip, 7601), timeout=6)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    hello = {"t": "hello", "name": "pane-pin-hold", "ver": 2, "device_id": device_id}
    s.sendall((json.dumps(hello) + "\n").encode())
    s.settimeout(6)
    try:
        raw = s.recv(MAX_LINE)
    except OSError as e:
        print("yanıt alınamadı:", e)
        s.close()
        return 1
    line = raw.split(b"\n", 1)[0].decode("utf-8", "replace")
    print("hello yanıtı:", line[:160])
    print(f"device_id={device_id}")
    print("kod ekranı bu süre boyunca açık kalacak; bu arada screencap al: "
          f"{hold_seconds()} sn")
    deadline = time.time() + hold_seconds()
    # Bağlantıyı canlı tutmak için ping: ping/pong doğrulama istemez ve durumu değiştirmez (§3).
    n = 0
    while time.time() < deadline:
        time.sleep(min(4.0, max(0.5, deadline - time.time())))
        if time.time() >= deadline:
            break
        try:
            s.sendall((json.dumps({"t": "ping", "now": int(time.time() * 1000)}) + "\n").encode())
            s.settimeout(3)
            if not s.recv(MAX_LINE):
                break
            n += 1
        except OSError as e:
            print("bağlantı koptu:", e)
            break
    print(f"pong={n}; kapatılıyor")
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
