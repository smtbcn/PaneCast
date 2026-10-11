# PaneCast

[English](README.md) | [Türkçe](README.tr.md)

Pick a window on your Mac and it appears full-screen on your Android TV, together with
that app's audio. The app is muted on the Mac while every other app keeps playing there.
Everything stays on your local network: no account, no cloud, no telemetry.

- Mac → Android TV today. A Windows sender is planned, not available.
- Window-only capture: the rest of your desktop is never sent.
- Open source, MIT.

## Download

Get the latest build from [GitHub Releases](../../releases):

| Platform | File |
|---|---|
| macOS (universal, Apple silicon + Intel) | `PaneCast-<version>-macOS.dmg` (or `.zip`) |
| Android TV | `PaneCast-Receiver-<version>.apk` |
| Windows | Planned, not available |

Check downloads against `SHA256SUMS.txt` from the same release.

## Install

**Mac**

1. Open the `.dmg` and drag PaneCast to Applications.
2. Start PaneCast. macOS asks for **Screen Recording** and **System Audio Recording**;
   allow both (System Settings → Privacy & Security). Restart the app if macOS asks you to.

**Android TV**

1. Sideload the `.apk`: copy it to the TV and open it from a file manager, or
   `adb install PaneCast-Receiver-<version>.apk`. Allow installs from that source if asked.
2. Open PaneCast on the TV. It shows a pairing code.

## Use

1. Put the Mac and the TV on the same network. Discovery is automatic (mDNS).
2. The first time, pair once: enter the code shown on the TV. The code never crosses the network.
3. Start a cast from either side: choose a window on the Mac, or ask for a stream from the TV.
4. The window shows full-screen on the TV with its audio. Stop from either side.

## Requirements

| | Minimum |
|---|---|
| Mac | macOS 14.2 for app audio isolation; macOS 14.0 works as video-only fallback |
| Android TV | Android 8.0 (API 26). Tested on an Android 11 TV |
| Network | Same LAN; wired Mac and 5 GHz Wi-Fi TV used for the numbers below |

The TV needs a hardware H.264 decoder (there is no software fallback).

## TV display mode

Pick **TV display (separate screen)** in the app to cast a whole virtual display instead of one window. The Mac opens a TV-sized 1920x1080 display named "PaneCast TV"; windows you move there (full screen is fine) and their audio play on the TV. Apps that leave that display are un-muted on the Mac again. Because the virtual display is always visible, switching apps on your main display no longer freezes the cast (a full-screen window on the main display is hidden by macOS when you switch away). CLI: `mirror --tv <ip> --tv-display`.

- System Settings → Desktop & Dock → "Displays have separate Spaces" must stay on (the default).
- The mode relies on a private macOS API (CoreGraphics virtual displays). A future macOS update could break it; the app then disables the mode with a message instead of crashing.

## Performance

Measured on one setup: Mac mini M4 on Ethernet, Android 11 TV on 5 GHz Wi-Fi. Other
networks and devices will differ.

| Metric | Result | Source |
|---|---|---|
| Capture | 1080p60 | Measured |
| Rendered on TV | ~58 fps, 0 dropped frames over 60 s | Measured |
| Decode-to-render latency | p50 ≈ 9 ms | Measured (TV-side) |
| Audio/video sync error | p95 ≈ 5–8 ms | Measured (software timestamps) |
| Loss recovery | 0 unrecovered packets at 1% and 3% injected loss | Measured |

These are software timestamps. They do **not** prove glass-to-glass latency; that was not measured.

## How it works

```
Mac                                                       Android TV
ScreenCaptureKit (one window) → VideoToolbox H.264 ─┐
                                 RTP/UDP, pacing,   ├──→  RTP → MediaCodec (hardware) → screen
                                 NACK retransmit  ──┘
Core Audio process tap (that app only) → L16 RTP ───────→  jitter buffer → AudioTrack
shared clock for A/V sync
TCP control channel (pairing, start/stop)  ←────────────→  mDNS discovery
```

- Video: window capture, hardware H.264, RTP over UDP with paced sending and NACK retransmission of lost packets.
- Audio: a Core Audio process tap captures only the chosen app, sent as 16-bit PCM over RTP and played through a jitter buffer. Video and audio share one clock for lip sync.
- Control and discovery: TCP control channel; mDNS finds the TV and the Mac.
- Wire details: [`docs/protocol.md`](docs/protocol.md).

## Privacy

No account, no cloud, no telemetry, no analytics. PaneCast talks only to the devices on your
local network that you pair with. It needs no internet connection to run.

## Security

- Pairing uses an ephemeral key exchange confirmed by the on-screen code; the code never crosses the network.
- **The media stream (video and audio) is not encrypted on the LAN.** Someone on the same network who can capture traffic could view it. Use a network you trust.
- Details and how to report problems: [`SECURITY.md`](SECURITY.md).

## Limitations

- Audio isolation is **per application, not per browser tab**: casting a browser window sends and mutes all audio of that browser app.
- Minimized windows and some Spaces can stop capture.
- One TV, one session at a time.
- No Windows sender yet.
- Unprotected media stream (see Security).

## Build from source

Sender (macOS): developed with Xcode 27 / Swift 6.4 on macOS 26; the package targets macOS 14.

```bash
./scripts/build-sender-app.sh debug      # → artifacts/build/PaneCast.app
(cd src/sender-macos && swift test)
```

Screen Recording is only granted to a real `.app` bundle, so run the bundle, not the raw binary.

Receiver (Android TV): JDK 17, Gradle 8.14, Android SDK (platform 36).

```bash
cd receiver && gradle assembleDebug       # no third-party dependencies, no AndroidX
```

Release builds and signing: [`docs/RELEASING.md`](docs/RELEASING.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Short version: measured improvements over new
features, no new runtime dependencies, no personal data in the repository.

## License

[MIT](LICENSE).
