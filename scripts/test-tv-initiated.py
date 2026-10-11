#!/usr/bin/env python3
"""TV'nin başlattığı yayın yönünü (TV → Mac çağrı, Mac → TV akış) uçtan uca doğrular.

Yayın akışı gerçek bir TV olmadan test edilemez; bu betik TV'nin rolünü protokol
düzeyinde üstlenir: 7610'a bağlanır, HMAC kanıtı verir, `resume` ister, Mac'in
yazdığı `start` parametrelerini okur, `started` diye yanıtlar ve UDP'de RTP'yi sayar.

Geçici olarak Anahtar Zinciri'ne 127.0.0.1 için bir test anahtarı yazar (yalnız
artifacts/build içindeki uygulama paketine güvenilir) ve biterken siler. Protokol v2:
iki uç da `ready` aşamasında anahtarı bildiğini kanıtlar.
"""
import base64
import hashlib
import hmac
import json
import os
import socket
import struct
import threading
import sys
import time

import subprocess

CONTROL_PORT = 7610
VERSION = 2
SERVICE = "dev.atvm.sender"          # KeyStore.swift: Anahtar Zinciri servis adı
TEST_HOST = "127.0.0.1"
APP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "artifacts", "build", "PaneCast.app")


def proof(key: bytes, channel: str, role: str, server_nonce: bytes, client_nonce: bytes) -> bytes:
    return hmac.new(key, f"atvm-auth-v2|{channel}|{role}".encode() + server_nonce + client_nonce,
                    hashlib.sha256).digest()


def seed_key(key: bytes) -> None:
    """127.0.0.1 için geçici test anahtarı; uygulama paketi istemsiz okuyabilsin diye -T ile güvenilir."""
    subprocess.run(["security", "add-generic-password", "-U", "-s", SERVICE, "-a", TEST_HOST,
                    "-l", "PaneCast test anahtarı", "-T", APP, "-X", key.hex()], check=True)


def drop_key() -> None:
    subprocess.run(["security", "delete-generic-password", "-s", SERVICE, "-a", TEST_HOST],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def lines(sock):
    buf = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError("Mac bağlantıyı kapattı")
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if line.strip():
                yield json.loads(line)


def main() -> int:
    duration = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0

    key = os.urandom(32)
    seed_key(key)

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))
    media_port = udp.getsockname()[1]
    udp.settimeout(1.0)

    packets = bytes_rtp = keyframes = 0
    starts = [1]   # TV'ye giden `start` bildirimi sayısı (pencere değişimini kanıtlar)
    audio_packets = audio_bytes = 0
    audio_abs_sum = audio_abs_n = 0
    ssrc_seen = set()
    error = None
    try:
        s = socket.create_connection(("127.0.0.1", CONTROL_PORT), timeout=5)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        stream = lines(s)

        def send(obj):
            s.sendall((json.dumps(obj) + "\n").encode())

        send({"t": "hello", "role": "receiver", "name": "test-tv", "ver": VERSION})
        m = next(stream)
        if m.get("t") != "challenge" or m.get("ver") != VERSION:
            raise RuntimeError(f"v{VERSION} challenge beklenirken: {m}")
        nonce_mac = base64.b64decode(m["nonce_mac"])
        nonce_tv = os.urandom(16)
        send({"t": "proof", "nonce_tv": base64.b64encode(nonce_tv).decode(),
              "proof": base64.b64encode(proof(key, "rev", "tv", nonce_mac, nonce_tv)).decode()})
        m = next(stream)
        if m.get("t") != "ready":
            raise RuntimeError(f"ready beklenirken: {m}")
        # Karşılıklı kanıt: Mac de anahtarı bildiğini göstermeli.
        if not hmac.compare_digest(base64.b64decode(m.get("proof", "")),
                                   proof(key, "rev", "mac", nonce_mac, nonce_tv)):
            raise RuntimeError("Mac'in ready kanıtı tutmadı")

        send({"t": "resume", "media_host": "127.0.0.1", "media_port": media_port, "name": "test-tv"})
        m = next(stream)
        if m.get("t") != "start":
            raise RuntimeError(f"start beklenirken: {m}")
        print(f"start: {m['width']}x{m['height']}@{m['fps']} "
              f"{int(m['bitrate']) // 1_000_000}Mbps ssrc={m['ssrc']} pt={m['payload_type']} "
              f"ses: pt={m.get('audio_payload_type')} ssrc={m.get('audio_ssrc')} "
              f"{m.get('audio_sample_rate')}Hz/{m.get('audio_channels')}ch")
        send({"t": "started", "media_port": media_port})

        # Gerçek TV gibi davran: sonraki `start`lara (pencere değişimi) de `started` yanıtı ver.
        s.settimeout(None)   # kalıcı yanıtlayıcı: sessizlikte zaman aşımına uğramasın

        def responder():
            for msg in stream:
                if msg.get("t") == "start":
                    starts.append(1)
                    print(f"  ek start: {msg['width']}x{msg['height']} ssrc={msg['ssrc']}", flush=True)
                    send({"t": "started", "media_port": media_port})
        threading.Thread(target=responder, daemon=True).start()

        deadline = time.time() + duration
        idr_sent = False
        while time.time() < deadline:
            try:
                pkt, _ = udp.recvfrom(65536)
            except socket.timeout:
                continue
            if len(pkt) < 12 or pkt[0] >> 6 != 2:
                continue
            packets += 1
            bytes_rtp += len(pkt)
            pt, ssrc = pkt[1] & 0x7F, struct.unpack(">I", pkt[8:12])[0]
            if pt == 97:
                audio_packets += 1
                audio_bytes += len(pkt) - 12
                import struct as _s
                samples = _s.unpack(f">{(len(pkt) - 12) // 2}h", pkt[12:])
                audio_abs_sum += sum(abs(v) for v in samples)
                audio_abs_n += len(samples)
                continue
            ssrc_seen.add(ssrc)
            body = pkt[12:]
            if body and (body[0] & 0x1F) in (5, 28):
                keyframes += 1
            if packets == 40 and not idr_sent:
                idr_sent = True
                send({"t": "idr_request"})
        s.close()
    except Exception as exc:  # test betiği: hatayı sayıyla birlikte raporla
        error = str(exc)
    finally:
        udp.close()
        # 127.0.0.1 kaydı yalnız bu test içindir; kalıcı olursa kullanıcı listesine sızar.
        drop_key()

    print(f"start bildirimi={len(starts)}")
    print(f"RTP paketi={packets} bayt={bytes_rtp} ana-kare={keyframes} ssrc={sorted(ssrc_seen)}")
    level = (audio_abs_sum / audio_abs_n) if audio_abs_n else 0
    print(f"ses paketi={audio_packets} bayt={audio_bytes} ortalama|genlik|={level:.0f}/32767 " +
          ("(yakalanan uygulamanın sesi yok gibi)" if audio_packets == 0 else ""))
    if error:
        print("HATA:", error)
    ok = packets > 50 and not error
    print("SONUÇ:", "GEÇTİ" if ok else "KALDI")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
