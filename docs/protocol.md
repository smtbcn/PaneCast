# Pane Cast Protocol v2

> English original. Türkçe: [protocol.tr.md](protocol.tr.md)

Single-source specification. Implementations:
- macOS: `src/sender-macos/Sources/ATVMSender/{Pairing,KeyStore,ControlClient,SenderServer,Transport,RtpRetransmit}.swift`
- Android TV: `receiver/app/src/main/java/dev/atvm/receiver/{Protocol,PasskeyPairing,Pairing,ControlLink,SenderConnector,RtpDepacketizer,VideoReorderBuffer}.kt`
- Test drivers: `scripts/test-tv-initiated.py`, `scripts/test-audio-source.py`, `scripts/test-receiver-reorder.sh`, `scripts/test-receiver-pairing.sh`

Labels: **Validated** = run between two real endpoints (Apple Silicon Mac ↔ Android TV receiver, API 30, 2026-10-10).

## 1. Carriers

| Channel | Carrier | Port | Status |
|---|---|---|---|
| Control (Mac → TV) | TCP, UTF-8 JSON per line (`\n` delimiter), `TCP_NODELAY` enabled | 7601 | Validated |
| Media | UDP, RTP (RFC 3550) + H.264 (RFC 6184) | 7602 | Validated |
| Discovery | mDNS/DNS-SD `_atvm._tcp.local.` | — | Validated (the TV's `NsdManager.registerService` → the Mac saw it with `dns-sd`/`NWBrowser`) |
| Reverse control (TV → Mac) | TCP, the same JSON-lines vocabulary | 7610 | Validated (Mac endpoint, `scripts/test-tv-initiated.py`) |
| Computer discovery | mDNS/DNS-SD `_atvm-sender._tcp.local.` | — | Validated (Mac `NetService` → seen by `dns-sd -B`; the TV's `NsdManager` list was validated with a screenshot) |

Fixed ports are enough for the MVP; the `start` message carries the port/PT notification in its
`media_port` and `payload_type` fields.
7610 is an **IPv4-only** socket: `NWListener` opened a single IPv6 slot on this machine and the TV's
IPv4 SYN was dropped (measured: connecting from the Mac to its own LAN IP works, from the TV a 6 s
timeout). That is why a POSIX `AF_INET` listener is used (`Tcp4Listener.swift`).

## 2. Discovery

- When the TV receiver app opens, it publishes the `_atvm._tcp` service:
  `serviceName = "ATVM-<Build.MODEL>"`, `port = 7601`, TXT: `ver`, `cport`, `mport`.
- The Mac browses for the announcements (`NWBrowser(.bonjour(type:"_atvm._tcp", domain:"local."))`).
- Fallback 1: the connection helper script (`scripts/tv-connect.sh`) browses the TV's built-in cast service record and reads its IP from it (Validated: device model in the TXT field and port 8009). The sender app itself does not browse that record — it only browses `_atvm._tcp`.
- Fallback 2: manual IP entry (required by the task).

## 3. Control messages

Common field: `t` (message type). An unknown `t` is logged. Malformed JSON → `denied/bad_json`; the
unauthenticated connection then closes. On both listeners (TV 7601, Mac 7610) the line ceiling is
**8192 bytes**; a connection that exceeds it closes. An unauthenticated connection that stays silent
for **15 s** closes (the TV waits 180 s after `pair_required` while the user types the code); in an
authenticated session there is no read timeout.

| Direction | `t` | Fields | Meaning |
|---|---|---|---|
| Mac→TV | `hello` | `name`, `ver` (=2) | session opening |
| TV→Mac | `pair_required` | `pin_ttl_ms`, `ver` | no pairing yet; 6-digit code on the TV screen |
| Mac→TV | `pair_init` | `pk` (b64, 65 B) | the Mac's ephemeral P-256 public key (§3.2) |
| TV→Mac | `pair_key` | `pk` (b64, 65 B) | the TV's ephemeral P-256 public key |
| both directions | `pk_commit` | `i`, `c` (b64, 32 B) | the commitment of round `i`: the Mac first, then the TV |
| both directions | `pk_open` | `i`, `n` (b64, 16 B) | the reveal of round `i`: the Mac first (the TV checks), then the TV (the Mac checks) |
| Mac→TV | `pair_confirm` | `mac` (b64) | the Mac's key confirmation (after the 20 rounds finish) |
| TV→Mac | `paired` | `session`, `mac` (b64) | key stored + the TV's key confirmation |
| Mac→TV | `pair_abort` | — | the Mac abandoned the attempt (the TV counts it as failed) |
| TV→Mac | `challenge` | `nonce_tv` (b64), `ver` | already paired; ask for proof |
| Mac→TV | `proof` | `nonce_mac` (b64), `proof` (b64) | session proof (§3.2) |
| TV→Mac | `ready` | `session`, `proof` (b64) | session open + the TV's proof; if it does not match, the Mac drops the connection |
| TV→Mac | `denied` | `reason`, (`ver`, `retry_after_ms`) | `version` / `locked` / `pin_mismatch` / `pin_expired` / `confirm_mismatch` / `bad_key` / `bad_message` / `auth_failed` / `not_paired` / `already_paired` / `unexpected_message` / `bad_json` |
| Mac→TV | `start` | `width,height,fps,bitrate,ssrc,media_port,payload_type` + `audio_ssrc,audio_payload_type,audio_sample_rate,audio_channels` + `sync,video_rtp_base,audio_rtp_base` | broadcast parameters (§4.1) and common clock bases (§5); only in an authenticated session |
| TV→Mac | `started` | `media_port` | decoder + UDP ready |
| TV→Mac | `cap_error` | `reason,max_width,max_height,codecs` | the TV rejected this profile |
| TV→Mac | `idr_request` | — | packet loss: request an urgent key frame |
| Mac→TV | `stop` | — | stop the broadcast; only in an authenticated session (otherwise `denied/not_paired`) |
| TV→Mac | `stopped` | `reason?` | stopped — the reply to `stop`/`unpair` **and** a broadcast that ended on its own on the TV (STOP from the remote, surface loss, decoder error). On seeing this message the Mac cuts the broadcast; it writes no reply |
| Mac→TV | `unpair` | — | delete the pairing; only in an authenticated session. The TV writes `stopped/unpaired` and closes the connection |
| bidirectional | `ping`/`pong` | `now` | liveness; needs no authentication and changes no state |

### 3.1 The TV-initiated direction (choosing the computer from the remote)

The same vocabulary, the roles swap. The TV connects on 7610 to the computer it picked from the
`_atvm-sender._tcp` list; this way the broadcast can be started from either direction:

```
TV → Mac : hello     {role:"receiver", name, ver:2}
Mac → TV : challenge {nonce_mac, ver:2}      (no record → denied/not_paired, version mismatch → denied/version)
TV → Mac : proof     {nonce_tv, proof = P(K, "rev", "tv",  nonce_mac, nonce_tv)}
Mac → TV : ready     {proof = P(K, "rev", "mac", nonce_mac, nonce_tv)}   (the TV drops it if it cannot verify)
TV → Mac : resume    {media_host, media_port, name}
Mac → TV : start     {width,height,fps,bitrate,ssrc,media_port,payload_type,audio_*,sync,video_rtp_base,audio_rtp_base}
TV → Mac : started | cap_error            (decoder + UDP socket set up)
... then the normal flow: TV → Mac idr_request, Mac → TV RTP/UDP, stop from either side
```

- The connection **stays open**: IDR requests and broadcast termination go over this socket.
- `idr_request`, `stop` and the closing of the connection affect the broadcast only after `ready`; an
  unauthenticated connection cannot stop a broadcast (`SenderServerTests`).
- If no window is selected in the Mac's UI, the Mac writes `denied/no_window_selected_on_sender`; it
  does not hand a random window to the network.
- The TV's pairing key is kept on the Mac in the Keychain under the TV's IP (§3.3).
- Measured (2026-10-10, v1 handshake, `scripts/test-tv-initiated.py`, the TV role simulated by the script):
  57.5 fps capture, a key frame after `idr_request`, and on a break the broadcast stopped within 1 s.
  The v2 handshake was validated on the Mac endpoint with a unit test; the script was updated to v2 but
  was not re-run with the UI. **The TV endpoint could not be validated on the device** (choosing the
  computer requires a remote control).

### 3.2 Pairing cryptography (v2)

Structure: Bluetooth LE Secure Connections **Passkey Entry** (ephemeral ECDH P-256 + a
commit/reveal round for each bit of the PIN). Platform cryptography only: macOS CryptoKit, Android
`java.security`/`javax.crypto`. The PIN is a 6-digit random number generated on the TV with
`SecureRandom` (`0…999999`, 20 bits); it appears only on the TV screen and the user types it into
the Mac. **Neither the PIN nor any digest derived from the PIN crosses the network.**

```
pkMac, pkTv   : X9.63 uncompressed P-256 point (65 B); a new ephemeral key per attempt
DH            : ECDH x coordinate (32 B). Off-curve points and the peer reflecting its own key are rejected.
TH0           : SHA-256("atvm-pair-v2" ‖ pkMac ‖ pkTv)
kc            : HKDF-SHA256(ikm = DH, salt = TH0, info = "atvm-pk-commit-v2", L = 32)
r_i           : the i-th bit of the PIN (i = 0…19, least significant bit first)
Ca_i / Cb_i   : HMAC-SHA256(kc, "M"/"T" ‖ i ‖ r_i ‖ Na_i/Nb_i)      (N: 16 B random, i and r_i one byte each)
round i       : Mac→Ca_i, TV→Cb_i, Mac→Na_i (the TV checks Ca_i with its own r_i),
                TV→Nb_i (the Mac checks Cb_i with its own r_i)
TH            : SHA-256(TH0 ‖ Ca_0 ‖ Cb_0 ‖ Na_0 ‖ Nb_0 ‖ … ‖ Ca_19 ‖ Cb_19 ‖ Na_19 ‖ Nb_19)
K (persistent): HKDF-SHA256(ikm = DH, salt = TH, info = "atvm-pair-v2", L = 32)
confirm       : Mac→ HMAC(K, "atvm-confirm-v2|mac" ‖ TH),  TV→ HMAC(K, "atvm-confirm-v2|tv" ‖ TH)
session proof : P(K, channel, role, n_server, n_client) = HMAC(K, "atvm-auth-v2|<channel>|<role>" ‖ n_server ‖ n_client)
                channel "ctl" (Mac→TV 7601, server is the TV) / "rev" (TV→Mac 7610, server is the Mac); role is the side producing the proof
session       : SHA-256("atvm-fp-v2" ‖ K) first 4 bytes, hex (no key byte is ever shown)
```

- **Why the bits one at a time:** in every round the interposing attacker (behaving like the TV
  towards the Mac and like the Mac towards the TV) must bind the bit to its own commitment before the
  honest side reveals it; a wrong guess is rejected in that round. Since the PIN is new in every
  attempt, the success probability per attempt is at most **10⁻⁶**. The same bound applies to someone
  trying to pair directly with the TV without seeing the screen (one-way SAS would not have provided
  this: the TV's peer on the network could compute the SAS itself).
- **Passive listener:** because the commitment key `kc` is derived from the ECDH, it cannot test PIN
  bits against the revealed nonces (in standard Bluetooth the passkey is disclosed afterwards; here
  it is not). `K` also rests on the ECDH.
- The Mac sends its confirmation only after the user has entered the code and the 20 rounds have
  held; the TV stores the key only once that confirmation verifies, and the Mac only once the TV's
  confirmation verifies.
- **Attempt limit (TV):** every attempt (one that ends in failure after `pair_init` was received:
  wrong bit, break, timeout, `pair_abort`) retires the code and shows a new one. 3 failed attempts
  give a 30 s lock; the lock doubles on each repeat (at most 8 min) and resets on a successful
  pairing. While locked: `denied/locked` + `retry_after_ms`.
- Reconnection: TV `challenge{nonce_tv}`, Mac `proof{nonce_mac, P(K,"ctl","mac",…)}`, TV
  `ready{P(K,"ctl","tv",…)}` — both sides prove they know the key. In v1 only the client proved
  itself, and because the two channels used the same form, the TV's 7610 proof could have been
  reflected into 7601; the channel/role tags prevent that.
- Comparisons are constant-time (`MessageDigest.isEqual`, XOR accumulation in Swift).
- Shared test vector (fixed private key/nonce/PIN → expected commitment, `K`, confirmations and
  proofs): `src/sender-macos/Tests/ATVMSenderTests/PairingTests.swift` and
  `receiver/selfcheck/PairingSelfCheck.kt`; the values were produced with a pure-integer P-256
  implementation independent of CryptoKit.
- Validated (2026-10-11, Mac ↔ Android TV, debug build): wrong PIN ×3 → `pin_mismatch` ×3, then
  `locked` even with the correct PIN (29 s); pairing and broadcast after the lock; reconnection
  without a PIN with the same session fingerprint; in a pairing passing through a logging proxy, the
  6639-byte dump contains the PIN string 0 times, 40 `pk_commit` and 40 `pk_open`; v1 `hello` →
  `denied/version`; unauthenticated `unpair`/`stop` → `denied/not_paired`; 9000 bytes without a line
  end → the connection closed in 0.04 s; a silent connection closed in 15.0 s.

### 3.3 Key storage

- **Mac:** macOS Keychain, `kSecClassGenericPassword`, service `dev.atvm.sender` (the Keychain
  service name kept from the first release — not the app's bundle id, which is
  `app.panecast.sender`), account = the TV's IPv4 address, value = the 32-byte `K`. The access right
  depends on the signing identity: a package rebuilt with the same developer identity reads the
  record without asking (verified through another route and with a different build). With an
  unsigned (ad-hoc) build we expect macOS to ask for permission, because the signature changes on
  every build (not verified).
  The previous version's `paired_keys.json` file is migrated into the Keychain on first access and
  deleted; TV names stay in the `paired_names.json` file since they are no secret.
- **TV:** `pair_key_v2.bin` in the app-specific directory (only the app's UID reads it;
  `allowBackup="false"`, it goes neither to backup nor to the cloud). No hardware key store is
  used: an attacker with root privileges or physical access can read it (SECURITY.md). The v1 key
  (`session_key.bin`) is deleted on first launch, because it was derived from the PIN that travelled
  in clear text; moving to this version requires pairing anew once.
- For automated device testing only the **debug** build (`BuildConfig.DEBUG`) writes the generated
  code to logcat (`ATVM-Pairing: DEBUG eşleştirme kodu`); the release build writes the code nowhere.

## 4. Media: RTP + H.264

The RTP header is 12 bytes: `V=2, P=0, X=0, CC=0`, `M`, `PT`, `seq (u16)`, `timestamp (u32, 90 kHz)`, `SSRC`.

- `PT=96` (dynamic, announced by `start`) → H.264.
- `SSRC`: the 32-bit random session identity chosen by the broadcaster. The receiver drops packets
  whose SSRC does not match. **Test mode:** `start.ssrc = 0` → the receiver locks onto the SSRC of
  the first packet. Since external RTP generators do not always signal the SSRC, this mode is used
  only in automated tests (Validated).
- Payload: VideoToolbox output is length-prefixed (4-byte BE) NAL units; the broadcaster converts
  this to **Annex-B** (`00 00 00 01` start code) and prepends SPS/PPS before each keyframe.
  Validated: the `selftest` output `00 00 00 01 27 42 c0 …` → the first NAL type is 7 (SPS), then 8 (PPS).
- Fragmentation: a single NAL ≤ 1150 B goes directly, otherwise **FU-A** (type 28) fragments; `M=1`
  on the last packet of the AU.
- Size: `start.width/height` is the initial frame size; it preserves the window's aspect ratio (it fits
  the landscape profile box with a single uniform scale, aligned to 16). When the window is resized the
  broadcaster keeps the session and the SSRC and rebuilds the encoder with the new size (new SPS/PPS +
  IDR). The receiver takes the real size from the decoder output format and fits it to the screen without
  distorting the ratio (letterbox/pillarbox). On this TV the decoder buffer is allocated according to the
  first SPS and does not grow, so if the picture exceeds that size the receiver rebuilds the decoder and
  requests an IDR (Measured).
- Receiver (RtpDepacketizer): handles single-NAL / STAP-A / FU-A. Packets first pass through the
  reorder/NACK buffer (§4.2); on unrecoverable loss a partial AU is dropped and only an IDR AU reopens
  the decoder gate.

### 4.1 Audio: RTP + PCM (PT=97)

A second stream on the same UDP flow: `PT=97`, a **separate SSRC**, 48 kHz clock, **L16** (RFC 3551:
16-bit signed, network order = big endian), interleaved stereo. A packet is **5 ms = 240 samples per
channel**: 960 B payload + 12 B header = 972 B (below the MTU, no fragmentation), `M=1`. The receiver
writes the payload to an `AudioTrack`; the timestamp difference of consecutive packets is 240 (on a
break the timestamp jumps, see §5).

- Source (broadcaster): the **Core Audio process tap** (macOS 14.2+). All audio processes of the
  captured application (a browser's helper process, a WebKit GPU service) are taken as a
  single stereo mix; the same tap mutes those processes on the Mac too (`mutedWhenTapped`, which ends
  when the broadcast ends or the broadcaster dies). If the tap cannot be installed, the fallback is
  ScreenCaptureKit audio; on the fallback path **there is no muting on the Mac**. Audio is at
  application level, there is no per-tab separation.
- Conversion: float32 → int16, clipping + TPDF dither (an exact-zero input stays zero).
- Measured (2026-10-11, local tap test `atvm-sender audio-tap-test`, without sending to the TV): 601
  packets in 3.01 s (≈ 200/s, ≈ 1.55 Mbps), every timestamp step 240.
- The audio fields of the `start` message: `audio_ssrc`, `audio_payload_type`, `audio_sample_rate`,
  `audio_channels`. If `audio_payload_type < 0` arrives, the receiver does not open the audio channel
  (backwards compatible: an old broadcaster).

### 4.2 Video loss recovery: RTCP NACK and retransmission

Video packets are lost on Wi-Fi (measured: Mac Ethernet → AP → TV 5 GHz Wi-Fi, RTT ≈ 1.6 ms, a 12-seq
gap in a 45 s broadcast). Loss is recovered over the same UDP socket without opening a second path.
**Video only** is covered; audio (PT=97) is not NACKed (the ring is kept generically per SSRC, audio can
be added later).

**Receiver → broadcaster: Generic NACK** (RFC 4585 §6.2.1), a single non-compound RTCP packet:

```
 0                   1                   2                   3
|V=2|P=0| FMT=1 |   PT=205    |          length (32-bit word − 1)        |
|              sender SSRC (randomly chosen by the receiver)             |
|              media SSRC (the video SSRC)                               |
|              PID (16)         |          BLP (16)                     |   × N
```

- Socket: the UDP socket the media packets arrived on; the destination is the **source address/port of
  the video packets**. The broadcaster reads from the same connected UDP flow (`NWConnection`).
- `PID` is the lost seq, `BLP` a bit mask for the following 16 seq (bit0 = PID+1). The 16-bit wrap is
  handled correctly.
- The receiver's reorder buffer (`VideoReorderBuffer`): the next packet in order goes straight to the
  decoder line (no waiting, no copy); a packet that jumps ahead is taken into the buffer and the seq's
  in between are counted as "missing".
  - If it arrives within 2 ms it counts as a reordered packet (no NACK, `reordered`).
  - If it is still missing after 2 ms → NACK; still missing after 10 ms → once more.
  - If it does not arrive within 30 ms it is **given up on**: the access unit (AU) containing those
    packets is dropped, and the first AU after the loss is also treated as suspicious and dropped (the
    AU boundary cannot be known); what is waiting in the buffer is delivered in order.
- **IDR gate:** on a give-up (or decoder recovery / queue backlog) the receiver gives the decoder
  **no P AU at all** until an IDR; only an AU containing NAL type 5 opens the gate. A receiver waiting
  for an IDR sends `idr_request` and repeats it at 300 ms intervals until it arrives. The backpressure
  request is separate and limited to 2 s; the two limits do not use a shared timestamp.
- A retransmitted packet is the original bytes (same `seq`, `timestamp`, `SSRC`); the receiver
  de-duplicates by `seq`.

**Broadcaster:** the last **2048** RTP packets per SSRC are kept in a ring indexed by `seq` (recorded at
first transmission). When a NACK arrives, the packet in the ring is sent as-is. Limits: the retransmission
total is bounded by **25%** of the bitrate reference (§4.3) (token-bucket, 0.2 s burst allowance) and the
same `seq` repeats no sooner than 4 ms. A seq that is not in the ring (old/dropped) is ignored; the
receiver gives up after 30 ms and requests an IDR.

**Statistics** (receiver `ATVM-Stats`): `gap` = a packet lost on first transmission and NACKed, `nack` =
an RTCP packet sent, `rtx` = a packet that arrived after the NACK and filled the gap, `rtxLate` = a
packet that arrived after the give-up, `unrec` = a packet given up on. Expected: `gap = rtx + unrec`
(excluding those still in flight). The broadcaster's per-second line: `nackRx` (NACKs received), `rtxTx`
(retransmitted), `rtxSkip` (not in the ring / the 4 ms rule / budget), `injDrop` (injection drop),
`paceDrop` (pacer overflow).

**Known limit:** if the *last* packet of an AU is lost, the receiver notices it only when the next packet
arrives (on a static screen that is the next frame); until then the frame stays old on the screen.

### 4.3 Broadcaster pacing

The encoder used to emit an AU in a single burst (unbounded send queue, audio in the same queue). That
the burst stresses the AP queue is **an assumption, not measured**; pacing was added only to reduce that
risk. Now video packets pass through a token-bucket on a dedicated serial queue (`atvm.pacer`):

- rate = **2.5 × the bitrate reference**, burst ≤ **16 KB**. The reference = the greater of the target
  bitrate and the last measured input rate (250 ms sample, EWMA): so that the pacer does not become the
  bottleneck and drop frames when the encoder exceeds the target (measured: synthetic high-entropy
  content produced ≈ 33 Mbps against a 12 Mbps target); in the first version the rate depended on the
  target only and, with this content, ≈ 13 thousand packets (pacer overflow) were dropped in 60 s;
  following the measured rate removed that (`paceDrop=0`);
- audio packets **skip** the pacer (they do not wait behind a video burst);
- on the socket side, bytes handed to the network stack but not yet processed are limited to **64 KB**
  (the queue stays shallow, so audio sees no waiting either);
- if the pacer queue exceeds ≈ 150 ms (rate × 0.15 s, at least 64 KB), **all the oldest AUs** are dropped
  (video only), the encoder is asked for an IDR of itself and the event is logged (`paceDrop`); the same
  event is reported at most once every 300 ms.
- retransmissions do not enter the pacer (they have their own 25% budget).

### 4.4 Trial: loss injection

On the broadcaster, the `ATVM_DROP_VIDEO_PCT=<percent>` environment variable does not send that fraction
of the video packets **on first transmission** (the packet is kept in the ring and can be recovered via
NACK). Retransmissions are not dropped. At start a `SINAMA:` line is printed.
Verification: `scripts/test-receiver-reorder.sh` (receiver logic, JVM), `swift test` (ring, NACK parsing,
token-bucket, pacer queue).

### 4.5 Measurements (2026-10-11, Mac Ethernet → AP → TV 5 GHz Wi-Fi)

**Measured**, 1080p60 profile, synthetic source (deterministic content, ≈ 33.7 Mbps), 60 s per run.
Latency = the receiver's decoder input → render window (§5), i.e. it does not include network latency.
`idr` is the total request count; with this content the baseline is also ≈ 19 (decoder queue backlog,
unrelated to loss).

| Run | gap | nack | rtx | unrec | idr | fps | p50 / p95 ms |
|---|---|---|---|---|---|---|---|
| old code (no recovery), no injection | 110 (all of them AU loss) | – | – | – | 20 | 57.1 | 34.2 / 65.1 |
| new code, no injection | 0 | 0 | 0 | 0 | 19 | 57.6 | 33.8 / 64.7 |
| new code, `ATVM_DROP_VIDEO_PCT=1` | 2180 | 2130 | 2180 | 0 | 19 | 55.4 | 33.5 / 64.8 |
| new code, `ATVM_DROP_VIDEO_PCT=3` | 6464 | 5711 | 6464 | 0 | 18 | 55.7 | 33.7 / 63.9 |

- In the old code `gap` was the raw seq hole (each one an AU loss + an IDR requirement); in the new code
  it is a packet lost on first transmission and NACKed.
- In the clean control run of the same session (`gap=4 unrec=4`) 4 consecutive packets were a real (not
  injected) loss and their retransmissions came later than 30 ms; this shows the give-up path works on a
  real network too.
- Extreme loss (`ATVM_DROP_VIDEO_PCT=40`, 25 s): the decoder was given only 3 AUs (≈ 1500 frames were
  produced); P frames were held until the IDR came and `idr_request` went out at 300 ms intervals (82
  requests). That is, no corrupt frame was fed in.
- Real window (a video player window, 1080p60 profile): `=1` → gap 473, rtx 473, unrec 0, idr 1; `=3` → gap
  150, rtx 150, unrec 0, idr 1; audio packets were unaffected (12187 sent / 12076 received, the receiver's
  line reads about 1 s behind). In these conditions the content changed from run to run (the player window
  window was sometimes static), which is why the latency comparison was made only on the synthetic table.
- Could not verify: the picture showing no visible corruption after loss with real content (`screencap`
  does not capture the video layer); the counters were used instead (IDR requests grew only together with
  `unrec`, and no AU outside the gate was given to the decoder).

## 5. Timing and latency

- The broadcaster produces the RTP timestamp at 90 kHz from `pts` relative to the common root (§5.1); the
  receiver renders **immediately** with `releaseOutputBuffer(idx, true)` (on a live projection, waiting for
  the frame increases latency).
- The receiver's queue is limited to 3 AUs; when it fills, the **oldest** is dropped (`drop_q`), so no
  backlog builds up.
- Latency measurement: the moment an AU is handed to the decoder is written into a FIFO, and it is taken
  out in order at render time (the order is preserved because there are no B-frames). `presentationTimeUs`
  is NOT used — this decoder re-bases it. `inflight = fed - rendered` gives the real backlog.
- Measured (2026-10-10, these two devices):
  - real window 672x438@60: decoder input → render **p50 3.3–4.0 ms, p95 4.3 ms**, backlog 0–3 frames
  - synthetic 720p60 (high entropy, 14 Mbps): **p50 23.0 ms, p95 31.3 ms**, backlog 1–2 frames
- These numbers do not include the TV panel/processing latency or the SCK capture duration.

### 5.1 Common clock (A/V sync)

If `start.sync = 1`, the RTP timestamps of the two streams are tied to **the same root instant**. The root
is a moment picked at the start of the broadcast in the Mac's host clock (mach absolute time; the same axis
as the ScreenCaptureKit video PTS and the Core Audio `mHostTime`); what is reported to the TV is not that
moment itself, but two bases corresponding to it:

```
start: "sync": 1, "video_rtp_base": <u32>, "audio_rtp_base": <u32>

video_ts = video_rtp_base + round((pts_host_sn            - root_sn) * 90000)   (mod 2^32)
audio_ts = audio_rtp_base + round((first_sample_host_sn   - root_sn) * 48000)   (mod 2^32)

=> (video_ts - video_rtp_base) / 90000  ==  (audio_ts - audio_rtp_base) / 48000   points to the same instant
```

- The audio timestamp is derived from the sample counter (continuity); if the moment implied by the
  counter and the host time reported by the device diverge by **more than 20 ms**, the broadcaster
  re-anchors to the host time (the timestamp jumps, the broadcaster logs it).
  The receiver must treat this jump as a gap (forward) or an overlap (backward).
- On the fallback ScreenCaptureKit audio path the same rule is applied with the `CMSampleBuffer` PTS.
- If `sync` is missing or `0`, the bases are meaningless; old receivers ignore the new fields (§7) and the
  streams are played as before, independent of the timestamps.
- Receiver (AvClock): the media time `m` µs is played/shown locally at `m·1000 + P` ns; P = max(audio
  path, video path), measured live. Because on this TV the audio path (HAL ~110 ms) dominates, the video is
  held ~160 ms at the decoder INPUT (`releaseOutputBuffer(i, future_ns)` broke frame production on this
  decoder). Measured (2026-10-11, 40 s, software timestamps): avErr p50 ≈ −1 ms, |p95| 4–8 ms; glass-to-glass
  alignment needs human checking (ADR-006).

## 6. Error behaviour

| Condition | Behaviour |
|---|---|
| The TV cannot set up the decoder | `cap_error` + the supported limits; the Mac does not start the broadcast |
| The control channel closes | The receiver stops the broadcast, returns to the `HAZIR` state and keeps listening |
| A video packet is lost and not recovered by NACK within 30 ms | The affected AU is dropped, no P AU is given to the decoder until an IDR arrives, `idr_request` (at 300 ms intervals) |
| UDP silence > 1.5 s | The receiver feels it through `soTimeout`; if the Mac does not send `stop`, the IDR request loop spins uselessly (M2: a watcher timeout) |
| The PIN's time is up | The TV shows a new code; a `pair_init` arriving with the old code → `denied/pin_expired` (not counted as a failure) |
| A pairing attempt fails | The code is renewed; 30 s lock after 3 failures (×2 on each repeat, at most 8 min), `denied/locked` |
| A different protocol version | The server writes `denied{reason:"version", ver:2}` and closes; a v2 Mac connecting to a v1 TV reports a version error because the reply has no `ver` |
| The Surface is destroyed (TV sleep) | The receiver stops the broadcast (Validated: logged when dreamx came to the front) |

## 7. Version policy

`hello.ver = 2` (v2: passkey pairing + mutual session proof). `ver` increases on a backwards-incompatible
change; the server returns `denied{"reason":"version","ver":N}` and the `hello` replies carry `ver`.
When adding a feature in a field, old endpoints must be able to ignore it (JSON, no required fields).
