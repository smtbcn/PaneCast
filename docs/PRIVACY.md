# Privacy policy

**Applies to:** PaneCast Receiver (Android TV) and PaneCast Sender (macOS).
**Last updated:** 2026-10-11

PaneCast shows a window or a dedicated screen from your own computer on your own TV over your local
network. It does this without any service of ours, so there is nothing for us to know about you.

## We do not collect anything

- No accounts, no sign-in, no analytics, no crash reporting, no advertising, no tracking.
- No data is sent to us or to any third-party server. Neither app contains a network client that
  targets anything outside your own local network.
- There is no PaneCast backend. The source is public and auditable.

## What stays on your local network

When you start a broadcast, the sender streams H.264 video and PCM audio to the TV over UDP, and the
two devices exchange control messages over TCP. Everything on that link is confined to your LAN:

- **Screen content and sound** of whatever you choose to cast. Anybody able to join your local network
  segment and the media port could observe this traffic; the stream is not encrypted. Cast only on
  networks you trust.
- **A pairing code** that is shown on the TV screen and typed into the sender by you. It is used to
  derive the session key for that pairing. The code itself is not stored on either device afterwards,
  and the pairing can be removed at any time from the TV (hold BACK) or from the sender.
- **Device names and addresses** (mDNS service discovery, LAN IP/port, TV model name) are used to find
  and reconnect to your own devices. A pairing record is kept on the sender in a local file so you do
  not have to re-enter the code every time. Removing the pairing deletes it.

Nothing leaves your network: no image, no audio, no identifier, no diagnostic.

## Logs

The macOS sender writes a local log file (its own session activity, and the same lines shown in its
window). The Android TV receiver writes standard Android logs. Logs stay on your devices. They are not
uploaded, and we never ask for them; if you report a bug, sending us a log is entirely your choice.

## Permissions the apps need, and why

- **Android TV receiver:** `INTERNET` and local-network socket/multicast permissions to receive your
  stream; no location, no contacts, no microphone, no camera, no storage permission, no accounts.
- **macOS sender:** Screen Recording (to capture the window or screen you pick) and System Audio
  Recording (to capture the audio of the applications you cast). Both are granted by you in System
  Settings and can be revoked there at any time; the app does not capture anything without them.

## Children

PaneCast is a tool for an adult's own devices and collects no personal information of anyone.

## Changes

If this policy changes, the new version is published in this repository, and the date above is updated.

## Source

The code that implements all of the above is open source; the repository link is in `README.md`.
