#!/usr/bin/env python3
"""Alıcının eşleşme tablosunu gerçek TV'de yoklar (salt-okunur; anahtar üretmez, yayın açmaz).

Neden bu betik: çok-bilgisayarlı eşleşme değişikliğinin (docs/protocol.md §3.3-3.4) cihazda
davrandığını, GUI sürmeden ve Anahtar Zinciri'ndeki sır değere dokunmadan kanıtlamak.

Üç yoklama, aynı `hello` çerçevesiyle:
  1) idsiz `hello` (eski yayıncı)  → `challenge` beklenir: tek dosyalık eski anahtar tabloya
     "id'siz kayıt" olarak taşındı ve `paired` hâlâ doğru.
  2) geçerli biçimde yeni `device_id` → `pair_required` beklenir: ilk bilgisayar eşleşik
     dururken İKİNCİ bilgisayar eşleşebilir (eski davranış: `already_paired` + ret).
  3) `challenge` alanına yanlış anahtarla `proof` → `denied/auth_failed` beklenir: tablodaki
     her anahtar sınanıyor ve iddia edilen `device_id` yetkilendirme girdisi yapılmıyor.

Kullanım: scripts/test-receiver-table.py [TV_IP]   (boşsa TV_IP ortam değişkeni / mDNS)
Bağımlılık yok (yalnız standart kütüphane).
"""
from __future__ import annotations

import base64
import json
import os
import socket
import subprocess
import sys
import time


def tv_address() -> str | None:
    if len(sys.argv) > 1:
        return sys.argv[1]
    env_ip = os.environ.get("TV_IP")
    if env_ip:
        return env_ip
    # mDNS: _atvm._tcp kaydının hedef adını çöz (betikler zaten bu sırayı kullanıyor).
    try:
        listing = subprocess.run(
            ["dns-sd", "-B", "_atvm._tcp", "local."], capture_output=True, text=True, timeout=4
        ).stdout
    except Exception:
        return None
    for line in listing.splitlines()[3:]:
        parts = line.split(None, 6)
        if len(parts) < 7:
            continue
        name = parts[6]
        try:
            resolved = subprocess.run(
                ["dns-sd", "-L", name, "_atvm._tcp", "local."],
                capture_output=True, text=True, timeout=4,
            ).stdout
        except Exception:
            continue
        host = None
        for row in resolved.splitlines():
            if "can be reached at" in row:
                host = row.split(":", 1)[0].strip().rstrip(".")
                break
        if not host:
            continue
        try:
            out = subprocess.run(["dscacheutil", "-q", "host", "-a", host],
                                 capture_output=True, text=True, timeout=4).stdout
        except Exception:
            continue
        for line2 in out.splitlines():
            if line2.startswith("ip_address:"):
                return line2.split(":", 1)[1].strip()
    return None


def hello_line(name: str, device_id: str | None) -> str:
    m = {"t": "hello", "name": name, "ver": 2}
    if device_id:
        m["device_id"] = device_id
    return json.dumps(m) + "\n"


def read_line(sock: socket.socket, timeout: float = 6.0) -> dict:
    sock.settimeout(timeout)
    buf = b""
    while b"\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    return json.loads(buf.split(b"\n", 1)[0].decode("utf-8")) if buf.strip() else {}


def connect(ip: str) -> socket.socket:
    s = socket.create_connection((ip, 7601), timeout=6)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def probe_legacy(ip: str) -> dict:
    """idsiz hello → challenge (eski yayıncının tek kaydı tabloya taşındı)."""
    s = connect(ip)
    try:
        s.sendall(hello_line("pane-test-eski", None).encode())
        m = read_line(s)
        return {"beklenen": "challenge", "geldi": m.get("t"), "raw": m}
    finally:
        s.close()


def probe_second_computer(ip: str, device_id: str) -> dict:
    """Tanınmayan id + boş göz → pair_required (ikinci bilgisayar eşleşebilmeli)."""
    s = connect(ip)
    try:
        s.sendall(hello_line("pane-test-yeni", device_id).encode())
        m = read_line(s)
        return {"beklenen": "pair_required", "geldi": m.get("t"), "raw": m}
    finally:
        s.close()


def probe_wrong_key(ip: str) -> dict:
    """challenge alındıktan sonra yanlış anahtarla proof → auth_failed (iddiaya güven yok)."""
    s = connect(ip)
    try:
        s.sendall(hello_line("pane-test-eski", None).encode())
        first = read_line(s)
        if first.get("t") != "challenge":
            return {"beklenen": "auth_failed", "geldi": "challenge gelmedi", "raw": first}
        nonce_tv = first.get("nonce_tv", "")
        # Kurgusal anahtar: tablodaki hiçbir kayıtla HMAC eşleşmeyecek.
        fake_key = bytes(32)
        nonce_mac = os.urandom(16)
        proof = hmac_sha256(fake_key, b"atvm-auth-v2|ctl|mac" + base64.b64decode(nonce_tv)
                            + nonce_mac)
        msg = {"t": "proof", "nonce_mac": base64.b64encode(nonce_mac).decode(),
               "proof": base64.b64encode(proof).decode()}
        s.sendall((json.dumps(msg) + "\n").encode())
        m = read_line(s)
        return {"beklenen": "auth_failed", "geldi": m.get("reason") or m.get("t"), "raw": m}
    finally:
        s.close()


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    import hashlib
    import hmac
    return hmac.new(key, data, hashlib.sha256).digest()


def main() -> int:
    ip = tv_address()
    if not ip:
        print("TV bulunamadı: TV_IP ver ya da alıcı uygulamasını açık tut.")
        return 2
    # base64url 16 karakter = §3.4'teki geçerli biçim (12 rastgele bayt).
    fresh_id = base64.urlsafe_b64encode(os.urandom(12)).decode().rstrip("=")
    failures = 0
    for label, result in (
        ("eski yayıncı (idsiz)", probe_legacy(ip)),
        ("ikinci bilgisayar (yeni id)", probe_second_computer(ip, fresh_id)),
        ("yanlış anahtarla proof", probe_wrong_key(ip)),
    ):
        ok = str(result["beklenen"]) in str(result["geldi"])
        failures += 0 if ok else 1
        print(f"{'GEÇTİ' if ok else 'BAŞARISIZ'}  {label}: beklenen={result['beklenen']} "
              f"geldi={result['geldi']}")
        print(f"        yanıt: {json.dumps(result['raw'], ensure_ascii=False)[:200]}")
        time.sleep(0.4)
    print(f"eşleşme tablosu yoklaması: {'TÜMÜ GEÇTİ' if failures == 0 else f'{failures} BAŞARISIZ'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
