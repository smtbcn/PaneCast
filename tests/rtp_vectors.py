#!/usr/bin/env python3
"""RTP/H.264 paketleme-çözme vektörleri (docs/protocol.md §4).

Hem referans davranışı tanımlar hem de round-trip doğrulaması yapar:
  Annex-B → (Swift/Kotlin'ın yaptığı paketleme kurallarıyla) RTP paketleri → geri çöz → aynı baytlar.

Ürettiği tests/vectors/rtp.json dosyası, iki uçtaki birim testlerin
(beklenen paket sayısı/sırası/marker/PT/seq artışı) karşılaştırılacağı tek kaynaktır.

Kullanım: ./tests/rtp_vectors.py [--write]
"""
from __future__ import annotations

import argparse
import json
import os
import random
import struct
import sys

MAX_PAYLOAD = 1150
PT_H264 = 96
START = b"\x00\x00\x00\x01"


def split_annex_b(data: bytes) -> list[bytes]:
    """Annex-B'yi NAL birimlerine ayırır (3 ve 4 baytlık start code destekli)."""
    nalus: list[bytes] = []
    i = 0
    starts: list[int] = []
    while i < len(data) - 2:
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            starts.append(i + 3)
            i += 3
        elif i < len(data) - 3 and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 0 and data[i + 3] == 1:
            starts.append(i + 4)
            i += 4
        else:
            i += 1
    for idx, s in enumerate(starts):
        e = starts[idx + 1] - 3 if idx + 1 < len(starts) else len(data)
        if e > s:
            nalus.append(data[s:e])
    return nalus


def pack(annex_b: bytes, ssrc: int, seq0: int, ts: int) -> list[bytes]:
    """RFC 6184: tek NAL sığarorsa olduğu gibi, sığmıyorsa FU-A. AU'nun son paketinde M=1."""
    nalus = split_annex_b(annex_b)
    out: list[bytes] = []
    seq = seq0
    for n_idx, nalu in enumerate(nalus):
        last_nal = n_idx == len(nalus) - 1
        if len(nalu) <= MAX_PAYLOAD:
            out.append(header(seq, ts, ssrc, last_nal) + nalu)
            seq = (seq + 1) & 0xFFFF
            continue
        nri = nalu[0] & 0x60
        nal_type = nalu[0] & 0x1F
        body = nalu[1:]
        chunks = [body[i:i + MAX_PAYLOAD - 2] for i in range(0, len(body), MAX_PAYLOAD - 2)]
        for c_idx, chunk in enumerate(chunks):
            fu = (0x80 if c_idx == 0 else 0) | (0x40 if c_idx == len(chunks) - 1 else 0) | nal_type
            payload = bytes([28 | nri, fu]) + chunk
            out.append(header(seq, ts, ssrc, last_nal and c_idx == len(chunks) - 1) + payload)
            seq = (seq + 1) & 0xFFFF
    return out


def header(seq: int, ts: int, ssrc: int, marker: bool) -> bytes:
    return struct.pack("!BBHII", 0x80, PT_H264 | (0x80 if marker else 0), seq, ts, ssrc)


def unpack(packets: list[bytes], ssrc_expected: int) -> bytes:
    """Alıcı tarafı: RTP başlığını at, FU-A'ı birleştir, AU'yu Annex-B olarak geri kur."""
    out = bytearray()
    cur = bytearray()
    started = False
    for pkt in packets:
        b0, b1 = pkt[0], pkt[1]
        assert b0 >> 6 == 2, "RTP sürümü 2 olmalı"
        marker = bool(b1 & 0x80)
        pt = b1 & 0x7F
        assert pt == PT_H264, f"PT {pt}"
        seq, ts, ssrc = struct.unpack("!HII", pkt[2:12])
        assert ssrc == ssrc_expected
        payload = pkt[12:]
        nal_type = payload[0] & 0x1F
        if nal_type == 28:  # FU-A
            fu = payload[1]
            if fu & 0x80:  # start
                cur = bytearray([(payload[0] & 0xE0) | (fu & 0x1F)])
                started = True
            cur += payload[2:]
        elif 1 <= nal_type <= 23:
            cur = bytearray(payload)
            started = True
        else:
            raise AssertionError(f"beklenmeyen NAL tipi {nal_type}")
        if marker and started:
            out += START + bytes(cur)
            cur = bytearray()
            started = False
    return bytes(out)


def case(name: str, annex_b: bytes) -> dict:
    ssrc = 0x12345678
    seq0 = 60000
    ts = 90000
    packets = pack(annex_b, ssrc, seq0, ts)
    back = unpack(packets, ssrc)
    original_nals = split_annex_b(annex_b)
    roundtrip_nals = split_annex_b(back)
    assert original_nals == roundtrip_nals, f"{name}: round-trip bozuk"
    seqs = [struct.unpack("!H", p[2:4])[0] for p in packets]
    assert seqs == [(seq0 + i) & 0xFFFF for i in range(len(seqs))], f"{name}: seq süreksiz"
    assert seqs[-1] == (seq0 + len(seqs) - 1) & 0xFFFF
    assert packets[-1][1] & 0x80, f"{name}: son pakette marker yok"
    return {
        "ad": name,
        "ssrc": ssrc,
        "baslangic_seq": seq0,
        "timestamp": ts,
        "girdi_annexb_hex": annex_b.hex(),
        "nal_sayisi": len(original_nals),
        "paket_sayisi": len(packets),
        "marker_li_paket_indeksi": len(packets) - 1,
        "paketler_hex": [p.hex() for p in packets],
        "beklenen_cikti_hex": back.hex(),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="tests/vectors/rtp.json yaz")
    args = ap.parse_args()

    random.seed(7)
    sps = bytes([0x67]) + bytes(random.randrange(256) for _ in range(11))
    pps = bytes([0x08]) + bytes(random.randrange(256) for _ in range(5))
    small_idr = bytes([0x65]) + bytes(random.randrange(256) for _ in range(400))
    big_idr = bytes([0x65]) + bytes(random.randrange(256) for _ in range(4000))
    small_p = bytes([0x41, 0x9A]) + bytes(random.randrange(256) for _ in range(300))
    big_p = bytes([0x41, 0x9A]) + bytes(random.randrange(256) for _ in range(2400))

    cases = [
        case("tek-kucuk-nal", START + small_p),
        case("keyframe-sps-pps-idr", START + sps + START + pps + START + small_idr),
        case("fu-a-buyuk-idr", START + sps + START + pps + START + big_idr),
        case("fu-a-esik-1150", START + bytes([0x41]) + bytes(MAX_PAYLOAD - 1 for _ in range(MAX_PAYLOAD - 1))),
        case("karisik-fu-a", START + small_p + START + big_p),
    ]
    for c in cases:
        print(f"  ✓ {c['ad']}: {c['nal_sayisi']} NAL → {c['paket_sayisi']} RTP paketi → round-trip aynı")

    if args.write:
        out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, "rtp.json"), "w") as f:
            json.dump({"aciklama": "docs/protocol.md §4 referans vektörleri", "vektorler": cases}, f,
                      ensure_ascii=False, indent=1)
        print(f"yazıldı: {out}/rtp.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
