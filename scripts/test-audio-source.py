#!/usr/bin/env python3
"""Ses kaynağının uygulama bazlı mı sistem karışımı mı olduğunu deterministik ölçer.

TV'nin kontrol sunucusu (7601) taklit edilir; `atvm-sender mirror --app <AD>` ile
YAKALANAN pencere bilinçli olarak sabitlenir. Sonra iki koşum karşılaştırılır:

  A) yakalanan uygulama sessiz, ses BAŞKA bir süreçten çalınıyor
  B) yakalanan uygulamanın kendisi çalıyor

PT=97 paket sayısı ve ortalama |genlik| buna göre cevap verir:
A'da genlik > 0 ise ses sistem karışımıdır; A'da 0, B'de > 0 ise uygulama bazlıdır.

Kullanım: scripts/test-audio-source.py <yakalanacak-uygulama> <saniye> [dış-ses-komutu]
"""
import base64
import hashlib
import hmac
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "artifacts", "build", "PaneCast.app",
                   "Contents", "MacOS", "PaneCast")
CONTROL_PORT = 7601
SERVICE = "dev.atvm.sender"          # KeyStore.swift: Anahtar Zinciri servis adı
APP = os.path.dirname(os.path.dirname(os.path.dirname(BIN)))


def auth_proof(key: bytes, role: str, nonce_tv: bytes, nonce_mac: bytes) -> bytes:
    return hmac.new(key, f"atvm-auth-v2|ctl|{role}".encode() + nonce_tv + nonce_mac,
                    hashlib.sha256).digest()


def fake_tv(state: dict, media_port: int) -> None:
    """Tek oturumluk TV kontrol sunucusu: challenge → proof → ready, start → started."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", CONTROL_PORT))
    srv.listen(1)
    srv.settimeout(30)
    state["ready"] = True
    try:
        conn, _ = srv.accept()
    except OSError as exc:
        state["error"] = f"bağlantı beklenirken: {exc}"
        srv.close()
        return
    with conn:
        buf = b""

        def send(obj):
            conn.sendall((json.dumps(obj) + "\n").encode())

        def recv():
            nonlocal buf
            while b"\n" not in buf:
                chunk = conn.recv(4096)
                if not chunk:
                    return None
                buf += chunk
            line, buf = buf.split(b"\n", 1)
            return json.loads(line)

        nonce_tv = b""
        while True:
            m = recv()
            if m is None:
                return
            t = m.get("t")
            if t == "hello":
                # Eşleşmiş TV gibi davranılır (v2 eşleştirmesi ECDH ister; standart kütüphanede yok):
                # Anahtar Zinciri'ne konan test anahtarıyla karşılıklı kanıt.
                nonce_tv = os.urandom(16)
                send({"t": "challenge", "nonce_tv": base64.b64encode(nonce_tv).decode(), "ver": 2})
            elif t == "proof":
                nonce_mac = base64.b64decode(m.get("nonce_mac", ""))
                want = auth_proof(state["key"], "mac", nonce_tv, nonce_mac)
                if not hmac.compare_digest(base64.b64decode(m.get("proof", "")), want):
                    state["error"] = "Mac'in kanıtı tutmadı"
                    send({"t": "denied", "reason": "auth_failed"})
                    return
                send({"t": "ready", "session": "test", "proof": base64.b64encode(
                    auth_proof(state["key"], "tv", nonce_tv, nonce_mac)).decode()})
            elif t == "start":
                state["start"] = m
                send({"t": "started", "media_port": media_port})
            elif t == "stop":
                send({"t": "stopped"})
                return
            else:
                send({"t": "denied", "reason": "unexpected"})


def collect_media(state: dict, sock: socket.socket, seconds: float) -> None:
    deadline = time.time() + seconds
    sock.settimeout(1.0)
    while time.time() < deadline:
        try:
            pkt, _ = sock.recvfrom(65536)
        except socket.timeout:
            continue
        if len(pkt) < 12 or pkt[0] >> 6 != 2:
            continue
        pt = pkt[1] & 0x7F
        if pt != 97:
            state["video_packets"] += 1
            continue
        payload = pkt[12:]
        state["audio_packets"] += 1
        state["audio_bytes"] += len(payload)
        samples = struct.unpack(f">{len(payload) // 2}h", payload[: len(payload) // 2 * 2])
        state["abs_sum"] += sum(abs(v) for v in samples)
        state["abs_n"] += len(samples)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    app, seconds = sys.argv[1], float(sys.argv[2])
    external = sys.argv[3] if len(sys.argv) > 3 else None

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))
    media_port = udp.getsockname()[1]

    # 127.0.0.1 için geçici eşleşme anahtarı (yalnız uygulama paketine güvenilir); sonda silinir.
    key = os.urandom(32)
    subprocess.run(["security", "add-generic-password", "-U", "-s", SERVICE, "-a", "127.0.0.1",
                    "-l", "PaneCast test anahtarı", "-T", APP, "-X", key.hex()], check=True)
    state = {"video_packets": 0, "audio_packets": 0, "audio_bytes": 0,
             "abs_sum": 0, "abs_n": 0, "ready": False, "start": None, "key": key}
    server = threading.Thread(target=fake_tv, args=(state, media_port), daemon=True)
    server.start()
    while not state["ready"]:
        time.sleep(0.05)

    env = dict(os.environ, ATVM_MEDIA_PORT=str(media_port))
    proc = subprocess.Popen(
        [BIN, "mirror", "--tv", "127.0.0.1", "--app", app,
         "--media-port", str(media_port), "--duration", str(int(seconds) + 6),
         "--log", "/tmp/atvm-audio-sender.log"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)

    ext = None
    if external:
        time.sleep(1.5)
        ext = subprocess.Popen(["/bin/bash", "-c", external],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    collect_media(state, udp, seconds)
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    if ext:
        ext.terminate()
    udp.close()
    subprocess.run(["security", "delete-generic-password", "-s", SERVICE, "-a", "127.0.0.1"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    start = state["start"] or {}
    level = (state["abs_sum"] / state["abs_n"]) if state["abs_n"] else 0.0
    print(f"yakalanan={app!r}  dış-ses={'var' if external else 'yok'}  "
          f"start={'evet' if start else 'HAYIR'} ses_pt={start.get('audio_payload_type', '-')}")
    print(f"  görüntü paketi={state['video_packets']}  ses paketi={state['audio_packets']} "
          f"({state['audio_bytes']} B)  ortalama|genlik|={level:.0f}/32767")
    if state.get("error"):
        print("  hata:", state["error"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
