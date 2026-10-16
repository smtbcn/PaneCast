# Pane Cast — contribution guide

> English original. Türkçe: [CONTRIBUTING.tr.md](CONTRIBUTING.tr.md)

User documents: [README.md](README.md) (English) · [README.tr.md](README.tr.md). Release process: [docs/RELEASING.md](docs/RELEASING.md).

## What we look for
Low latency, few dependencies, behaviour verified on a real device. Not feature
multiplication; measured improvement.

## Mandatory rules
1. **License:** GPL/AGPL code must not enter the build. The repository contains only code
   we wrote ourselves; if a line is taken from a third-party project, the attribution
   notice is added at that moment.
2. **Publication cleanliness:** no other application's/project's name and no personal or
   device/network identity appears in the repository. The audit (`scripts/scrub-personal-data.py`) runs on every commit (`--check --worktree`) and on every push (`--check --all-history`), so a leak stops the commit instead of being found later.
3. **Evidence label:** the source of every number is stated — **Measured / Stated (device XML) /
   Target / Could not verify / Blocked**. Do not write that code "works" if you did not run it.
4. **Do not present the unsupported as supported** (reduced-scale window, Space, the Windows side).
5. **Dependencies:** the receiver must stay AndroidX-free/framework-only (32-bit, ~400 MB usable
   RAM target). A new dependency must be justified.
6. **Resource cleanup:** the `stopCapture → VTCompressionSessionInvalidate → socket/mDNS close`
   path must always work.

## Build and test order
```bash
./scripts/mac-encoder-probe.sh                 # encoder baseline measurement (needs no permission)
cd receiver && gradle assembleDebug               # a cache path can be chosen with GRADLE_USER_HOME
./scripts/build-sender-app.sh debug            # → artifacts/build/PaneCast.app
./scripts/test-tv-initiated.py 6   # verify end to end the direction where the TV starts the broadcast
<sender> selftest                              # Annex-B conversion
<sender> mirror --tv <ip> --source synthetic   # end-to-end line without needing permissions
<sender> mirror --tv <ip> --window <id>        # a real window (Screen Recording permission required)
```
CI (`.github/workflows/ci.yml`) runs three jobs: repository hygiene (the personal-data scan), the receiver build + `scripts/test-receiver-reorder.sh`, and the sender `swift build` + `swift test`.
Tests that require a real TV do not run in CI and are not counted as "verified".
`<sender>`: `artifacts/build/PaneCast.app/Contents/MacOS/PaneCast`.

## Commit
Small, single-topic, with a message containing the rationale. This repository uses its own
local git identity (`git config --local user.email`; the value is deliberately not written
here) and the machine-wide hook gate is disabled for this repository only via `core.hooksPath`.

## Guide
The only published design document: `docs/protocol.md` (everything about the wire transport is
there). Our architecture/analysis/measurement notes are not published; code comments and this
file are enough.
