# PaneCast {{VERSION}}

Show one Mac window full-screen on your Android TV, with that app's audio. Local network only.

## What's new

{{CHANGES}}

## Downloads

| File | For |
|---|---|
| `PaneCast-{{VERSION}}-macOS.dmg` | Mac (macOS 14.2+ for per-app audio, 14.0+ video only), universal arm64 + x86_64 |
| `PaneCast-{{VERSION}}-macOS.zip` | Same app as a zip |
| `PaneCast-Receiver-{{VERSION}}.apk` | Android TV (Android 8.0+, API 26) |
| `SHA256SUMS.txt` | Checksums of the files above |

Windows sender: planned, not available yet.

macOS build: {{MACOS_STATUS}}.

## Install

- Mac: open the `.dmg`, drag PaneCast to Applications, start it, allow Screen Recording and System Audio Recording.
- TV: sideload the `.apk` (file manager or `adb install`), open PaneCast; it shows a pairing code.

Details: see the README.

## Verify the download

```
shasum -a 256 -c SHA256SUMS.txt
```

SHA-256:

```
{{CHECKSUMS}}
```

## Known limitations

- Media stream is not encrypted on the local network.
- Minimized windows and some Spaces can stop capture.
- One TV, one session at a time.
- The Android APK from GitHub and a Google Play build are signed with different keys; they cannot update each other (uninstall first when switching).
