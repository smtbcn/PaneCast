#!/usr/bin/env python3
""" artifacts/tv/media_codecs*.xml dosyalarından TV'nin video çözümleme yeteneklerini özetler.
Kullanım: ./scripts/tv-codecs.py [artifacts/tv]  (yol verilmezse proje içi varsayılan kullanılır)"""
import glob
import os
import sys
import xml.etree.ElementTree as ET

root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "artifacts", "tv")

caps, perf = {}, {}
for path in sorted(glob.glob(os.path.join(root, "media_codecs*.xml"))):
    performance = "performance" in os.path.basename(path)
    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        print(f"!! {os.path.basename(path)}: {e}")
        continue
    for mc in tree.iter("MediaCodec"):
        name = mc.get("name", "?")
        entry = caps.setdefault(name, {"type": mc.get("type", ""), "features": [],
                                      "limits": {}, "measured": {}})
        if mc.get("type"):
            entry["type"] = mc.get("type")
        for child in mc:
            if child.tag == "Feature":
                entry["features"].append(child.get("name", ""))
            elif child.tag == "Limit":
                key, val = child.get("name", ""), child.get("range") or child.get("max") or child.get("value") or ""
                if key.startswith("measured-frame-rate-"):
                    entry["measured"][key.replace("measured-frame-rate-", "")] = val
                else:
                    entry["limits"][key] = val
        if performance:
            perf[name] = entry["measured"]

INTERESTING = ("video/avc", "video/hevc", "video/av01", "video/x-vnd.on2.vp9")
hardware = [n for n in caps if n.startswith(("OMX.MS.", "c2.vendor"))]

print("=== DONANIMSAL video çözücüler (ilgilenilen codec'ler) ===")
for name in hardware:
    e = caps[name]
    if e["type"] not in INTERESTING:
        continue
    size = e["limits"].get("size", "?")
    inst = e["limits"].get("concurrent-instances", "?")
    feats = ",".join(sorted(set(e["features"]))) or "-"
    perf_str = " ".join(f"{k}={v}" for k, v in sorted(e["measured"].items())
                        if k.startswith(("1280", "1920", "3840")))
    print(f"\n{name}  [{e['type']}]")
    print(f"  max çözünürlük={size}  eşzamanlı={inst}  özellikler={feats}")
    print(f"  ölçülmüş fps: {perf_str or 'YOK (performans XMLinde yok)'}")

print("\n=== YAZILIMSAL (google/c2.android) çözücüler — 1080p ölçüleri ===")
for name in sorted(n for n in caps if n.startswith(("c2.android.", "OMX.google."))):
    e = caps[name]
    if e["type"] not in INTERESTING:
        continue
    p = e["measured"]
    best = p.get("1920x1088") or p.get("1920x1080") or "?"
    print(f"  {name:<28} 1080p={best}")

print("\nNot: 'ölçülmüş fps' değerleri cihazın kendi /vendor/etc/media_codecs_performance.xml")
print("dosyasındadır (CTS tabanlı ölçüm); 'max çözünürlük' ve 'low-latency' beyanları")
print("media_codecs.xml'dendir. İkisi de bu depoya artefakt olarak kaydedilmiştir.")
