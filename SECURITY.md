# Security policy

> English original. Türkçe: [SECURITY.tr.md](SECURITY.tr.md)

Pane Cast is designed for **the local network only**. There is no internet listener, no cloud,
no account, no telemetry and no remote access.

## Supported version
This project ships from a tagged release line (currently the 0.2.x line; `VERSION` holds the current value). Only the newest release and `main` are supported — older releases are not patched, and pre-release builds carry no security guarantee.

## Reporting
Do not open a vulnerability as a **public issue**. Report it by the e-mail on the repository
owner's GitHub profile, or with a private security advisory (private vulnerability report).

## Threat model

The attacker is assumed to be **on the same local network** as the Mac and the TV.

- **Passive attacker** (only listens to the traffic): cannot learn the PIN or the pairing key
  from the pairing. **Sees and hears the published screen and audio content** (below).
- **Active attacker** (interposes, alters packets, impersonates the Mac or the TV): the
  probability of taking over a pairing is at most 10⁻⁶ per attempt; attempts are limited on
  the TV. Can corrupt the media stream, inject fake video and block the service (below).
- Out of scope: an attacker who can run code on the Mac or on the TV, has root privileges or
  has physical access.

## What is protected

| Element | Status |
|---|---|
| Pairing | The 6-digit code appears **only on the TV screen**; the user types it into the Mac. The code **never crosses the network**, and neither does a digest of it. Ephemeral ECDH P-256 plus a commit/reveal round for each of the code's 20 bits (Bluetooth LE SC Passkey Entry structure, details in `docs/protocol.md` §3.2). An interposing attacker must guess each bit before the honest side reveals it: per-attempt success ≤ 10⁻⁶. The same bound applies to someone trying to pair directly with the TV without seeing the screen. |
| Attempt limit | The code is renewed on every failed attempt; on the TV, 3 failed attempts give a 30 s lock, doubling on each repeat (at most 8 min). |
| Reconnection | **Mutual** HMAC proof with the persistent key, two fresh nonces per connection (one from each side), tagged with channel and role (the proof of one direction cannot be reflected into the other). The PIN is not asked again. |
| Authorization | `start`, `stop`, `unpair` (TV) and `resume`, `stop`, `idr_request` (Mac) are accepted only in an authenticated session. The closing of an unauthenticated connection does not stop the broadcast. `ping` requires no authentication and changes no state. |
| Resource consumption | The pre-authentication line limit is 8 KB; a silent connection closes in 15 s (TV 7601 and Mac 7610). |
| Version | Old-protocol (v1) endpoints get `denied/version`; v1 keys are invalid (the TV deletes them on first launch). |
| Key storage | Mac: macOS Keychain (`dev.atvm.sender`, account = the TV's IP); access is tied to the signing identity. The old `paired_keys.json` is migrated and deleted. TV: app-specific directory (`pair_key_v2.bin`), `allowBackup="false"`. |
| Logs | The PIN, the key and screen content are not logged. The single exception: the **debug** build writes the pairing code to logcat for automated testing; the release build does not. |
| macOS permission | Screen Recording only with the user's permission; on refusal the broadcast does not start. Casting a window's own audio additionally needs the System Audio Recording permission — without it the video still streams, the audio track stays silent. The broadcast starts only while a window (or the TV display) is selected on the Mac. |
| Scanning | Device discovery is done with mDNS; **no network scanning / no identity probing is performed**. |

## What is not protected (accepted weaknesses)

| Element | Status |
|---|---|
| **Media encryption** | **NONE.** Video and audio go over RTP/UDP in **clear text**. Anyone able to see the traffic on the same network can record the broadcast window and its sound. Pairing and session proof do not protect the media. |
| Media integrity | RTP packets are not authenticated. Someone on the network can listen for the SSRC and inject fake or corrupt packets to the TV; the receiver only checks SSRC/PT matching. |
| Control channel confidentiality | Control messages (`start` parameters, device names, IDR requests) are unencrypted; only session opening is authenticated. After the session opens, individual messages are not authenticated: an active attacker able to take over the TCP session can inject `stop` or `start` in that session. |
| Denial of service | The TV's control listener serves one connection at a time; someone on the network can delay pairing by connecting and waiting (15 s per connection; on an unpaired TV, 180 s while the code is awaited after `hello`), or by deliberately triggering the lock with wrong attempts. |
| TV key store | No hardware-backed key store is used (the dependency-free choice); an attacker with root privileges or physical access can read the `pair_key_v2.bin` file. |
| Device names | The `hello` messages carry the user-visible name of the Mac and of the TV in clear text; mDNS announcements also advertise the name to the network. |
| Ports | 7601/tcp and 7602/udp on the TV, 7610/tcp on the Mac (IPv4 only) listen on all interfaces; they listen while the app is open and do not listen when it is closed. |

## Vulnerability acceptance criterion
We consider serious only a weakness usable on the local network alone, without requiring
pairing (apart from the accepted weaknesses above). Something that requires internet access
is not a "weakness", it is outside the design.
