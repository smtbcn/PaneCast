#!/usr/bin/env python3
"""Yayınlama öncesi kişisel veri denetimi.

İki katmanda çalışır:
1. GENEL dedektörler — her depoda anlamlı kalıplar (MAC, UUID, Apple sertifika adı/TeamID,
   ev dizini yolu, e-posta, seri alanı, SSID).
2. YEREL kalıplar — isim/şirket/hesap gibi bu makineye özel sabitler. Bilerek koda
   gömülmediler; aksi halde denetimin kendisi kişisel veri taşırırdı.
   `scripts/privacy-patterns.local.txt` dosyasından okunur (gitignore'da).

Ayrıca commit METADATA'sı taranır: yazar/imzacı e-postaları (--all-history) ve bir sonraki
commit'in kullanacağı `git config` kimliği (--worktree). Dosya içeriği temiz olsa bile işveren
adresi geçmişte kamuya açılabilir (15.10.2026'da ölçüldü).

Kullanım:
  ./scripts/scrub-personal-data.py --check                  # iz varsa exit 1
  ./scripts/scrub-personal-data.py --check --all-history    # tarihçe blobları + commit kimlikleri
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELF = os.path.relpath(os.path.abspath(__file__), ROOT)
LOCAL_PATTERNS_FILE = os.path.join(ROOT, "scripts", "privacy-patterns.local.txt")

# Açık kaynak bir depoda bulunması kabul edilemez genel kalıplar.
GENERIC = {
    "ev-dizini-yolu": r"/Users/[A-Za-z0-9._-]+",
    "apple-sertifika-kimliği": r"(?:Apple (?:Development|Distribution)|Developer ID Application):[^\")\n]*\([A-Z0-9]{10}\)",
    "takım-id-bağlamı": r"TeamIdentifier\s*=\s*\[?[A-Z0-9]{10}",
    "e-posta": r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
    "mac-adresi": r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b",
    "bluetooth-adresi": r"\b[0-9A-F]{12}\b",
    "uuid": r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b",
    "cihaz-seri-alanı": r"ro\.serialno\s*=\s*\S+",
    "wifi-ssid": r"SSID\s*[:=]\s*\"?[A-Za-z0-9._-]{3,}",
    "yerel-ağ-ip": r"\b(?:192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b",
}

# Yayın kuralı: depoda başka bir projenin/uygulamanın adı geçmez (kendi kodumuz yetiyor).
THIRD_PARTY = (
    "tv-bridge", "deskreen", "sunshine", "moonlight", "omnicast", "mediamtx", "scrcpy",
    "obs-studio", "obs", "vlc", "ffmpeg", "gstreamer", "exoplayer", "webrtc",
    "piik", "firemirror", "rtsp-client-android", "libyuv", "ardour",
)

# Bu araç kalıpların kendisini içerir; kendi tanım satırları muaf.
SELF_ALLOW = {"ev-dizini-yolu", "e-posta", "takım-id-bağlamı", "apple-sertifika-kimliği",
              "cihaz-seri-alanı", "bluetooth-adresi", "üçüncü-taraf-yazılım-adı"}

# İçermesi beklenen/yerel dosyalar: denetim dışı.
EXEMPT = {"scripts/privacy-patterns.local.txt", "scripts/signing.local.sh",
          "scripts/signing.local.sh.example", "receiver/local.properties"}

# Bildirim/e-posta adresi gibi görünen ama kamuya açık olması sorun olmayan değerler.
ALLOW_VALUES = {"noreply@github.com", "opensource@example.com"}


def load_local(path: str) -> dict[str, str]:
    """Yasaklı yerel kalıplar. `+` ile başlayan satırlar kalıp değil, commit metadata'sında
    serbest olan kimlik değeridir (kamuya açık GitHub adresi gibi) — onlar `load_allowed`a gider."""
    out: dict[str, str] = {}
    if not os.path.isfile(path):
        return out
    for i, line in enumerate(open(path, encoding="utf-8")):
        value = line.rstrip("\n").strip()
        if not value or value.startswith("#") or value.startswith("+"):
            continue
        out[f"yerel-{i + 1}"] = re.escape(value)
    return out


def load_allowed(path: str) -> set[str]:
    """`+satır` biçimindeki izinli kimlik değerleri (yalnız commit metadata taramasında kullanılır)."""
    if not os.path.isfile(path):
        return set()
    return {line.rstrip("\n").strip()[1:].strip()
            for line in open(path, encoding="utf-8")
            if line.strip().startswith("+")}


def worktree() -> list[tuple[str, str]]:
    """İzlenen dosyaların çalışma ağacındaki hali (commit öncesi denetim için).
    TUZAK: spec'i çıplak yol olarak döndürmek `git cat-file`'a gider ve sessizce boş
    döner → taranmadan "temiz" sonucu çıkardı. WORKTREE: öneki diskten okutur."""
    res = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True)
    return [(f, "WORKTREE:" + f) for f in res.stdout.split()]


def tracked() -> list[tuple[str, str]]:
    res = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True)
    return [(f, "HEAD:" + f) for f in res.stdout.split()]


def history() -> list[tuple[str, str]]:
    res = subprocess.run(["git", "-C", ROOT, "rev-list", "--objects", "--all"],
                         capture_output=True, text=True)
    out = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2 and parts[1]:
            out.append((parts[1], parts[0]))
    return out


def read(spec: str) -> bytes:
    if spec.startswith("WORKTREE:"):
        p = os.path.join(ROOT, spec[9:])
        return open(p, "rb").read() if os.path.isfile(p) else b""
    if spec.startswith("HEAD:"):
        p = os.path.join(ROOT, spec[5:])
        return open(p, "rb").read() if os.path.isfile(p) else b""
    return subprocess.run(["git", "-C", ROOT, "cat-file", "-p", spec], capture_output=True).stdout


def commit_identities() -> list[tuple[str, str]]:
    """Ulaşılabilir tüm commit'lerin yazar/imzacı **e-postaları**.

    Neden ayrı bir tarama: dosya içeriği taranırken commit metadata'sı taranmıyordu.
    Ölçüldü (15.10.2026) — yayına hazırlanan depoya işveren kimliğiyle 5 commit yazılmıştı
    ve `--check --all-history` hiçbir şey bulmadı; push edilse kimlik kamuya çıkacaktı.
    Yalnız e-posta taranır: yazar adı, kamuya açık kimlikte de zorunlu olarak görünür.
    Değerler **yazdırılmaz**, yalnız hangi commit olduğu bildirilir.
    """
    res = subprocess.run(["git", "-C", ROOT, "log", "--all", "--format=%h%x09%ae%x09%ce"],
                         capture_output=True, text=True)
    out: list[tuple[str, str]] = []
    for line in res.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            out.append((f"commit {parts[0]} yazarı", parts[1]))
            out.append((f"commit {parts[0]} imzacısı", parts[2]))
    return out


def config_identity() -> list[tuple[str, str]]:
    """Bir sonraki commit'in kullanacağı e-posta: pre-commit'te erken uyarı.

    Depo-yeri `user.email` kurulmamışsa küresel değer miras alınır; iş makinesinde bu
    değer işveren adresi olabilir. Yanlış kimlikle commit yazıldıktan sonra düzeltmek,
    geçmiş yeniden yazmayı gerektirdiği için pahalıdır.
    """
    r = subprocess.run(["git", "-C", ROOT, "config", "--get", "user.email"],
                       capture_output=True, text=True)
    value = r.stdout.strip()
    return [("git config user.email", value)] if r.returncode == 0 and value else []


def scan_identities(local: dict[str, str], allowed: set[str], all_history: bool) -> list[tuple[str, str]]:
    """Yalnız YEREL kalıplarla ve izinli değerler düşülerek: genel e-posta kuralı, kamuya
    açık olması sorun olmayan kendi GitHub adresimizi de yakalardı."""
    hits: list[tuple[str, str]] = []
    for where, value in (commit_identities() if all_history else config_identity()):
        if value in allowed or value in ALLOW_VALUES:
            continue
        for name, pat in local.items():
            if re.search(pat, value, re.I):
                hits.append((where, name))
    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--all-history", action="store_true")
    ap.add_argument("--worktree", action="store_true",
                    help="HEAD yerine çalışma ağacındaki izlenen dosyalara bak (pre-commit)")
    args = ap.parse_args()

    patterns = dict(GENERIC)
    local = load_local(LOCAL_PATTERNS_FILE)
    allowed = load_allowed(LOCAL_PATTERNS_FILE)
    if local:
        print(f"yerel kalıp dosyası: {len(local)} kural"
              + (f", {len(allowed)} izinli commit kimliği" if allowed else ""))
    else:
        print("UYARI: scripts/privacy-patterns.local.txt yok — yalnız genel kalıplar taranıyor.")
    patterns.update(local)
    patterns["üçüncü-taraf-yazılım-adı"] = r"(?i)\b(?:%s)\b" % "|".join(re.escape(n) for n in THIRD_PARTY)

    items = (worktree() if args.worktree else tracked()) + (history() if args.all_history else [])
    seen: set[tuple[str, str]] = set()
    findings: list[tuple[str, str, str]] = []
    for path, spec in items:
        if path in EXEMPT or (path, spec) in seen:
            continue
        seen.add((path, spec))
        data = read(spec)
        if not data:
            continue
        text = data.decode("utf-8", "replace")
        for name, pat in patterns.items():
            if path == SELF and name in SELF_ALLOW:
                continue
            for m in re.finditer(pat, text):
                value = m.group(0)
                if value in ALLOW_VALUES:
                    continue
                lo = max(0, m.start() - 40)
                snip = text[lo:m.end() + 40].replace("\n", " ")
                findings.append((path, name, snip[:160]))

    identity_hits = scan_identities(local, allowed, args.all_history)

    if not findings and not identity_hits:
        print("temiz: kişisel/cihaz/ağ kimliği ve üçüncü taraf yazılım adı izi yok")
        return 0

    if findings:
        print(f"BULGU: {len(findings)} iz")
        for path, name, snip in findings[:40]:
            print(f"  {path}  [{name}]  …{snip}…")
        if len(findings) > 40:
            print(f"  … ve {len(findings) - 40} tane daha")
    if identity_hits:
        # Değerler bilinçli olarak yazdırılmaz: raporun kendisi kişisel veri taşımasın.
        print(f"BULGU: {len(identity_hits)} commit kimliği izi (değerler yazdırılmıyor)")
        for where, name in identity_hits[:20]:
            print(f"  {where}  [{name}]  → git config --local user.email ile doğru kimliği kur")
        if len(identity_hits) > 20:
            print(f"  … ve {len(identity_hits) - 20} tane daha")
    return 1


if __name__ == "__main__":
    sys.exit(main())
