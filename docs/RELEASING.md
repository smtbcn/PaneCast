# Releasing PaneCast

Release artifacts are built and signed **locally by the maintainer**. Nothing here runs in CI
and no signing material is ever committed (`dist/`, `*.jks`, `*.keystore`, `*.p12`,
`receiver/keystore.properties`, `scripts/*.local.*` are gitignored).

Artifacts for version `X.Y.Z` (single source of truth: the `VERSION` file at the repo root,
read by gradle and by the macOS scripts):

| File | Where it goes |
|---|---|
| `dist/PaneCast-X.Y.Z-macOS.dmg` and `.zip` | GitHub Release |
| `dist/PaneCast-Receiver-X.Y.Z.apk` | GitHub Release |
| `dist/SHA256SUMS.txt`, `dist/RELEASE_NOTES.md` | GitHub Release |
| `artifacts/play/PaneCast-Receiver-X.Y.Z.aab` | Google Play only (never attach to GitHub) |

Android `versionCode` is derived from `VERSION` as `major*10000 + minor*100 + patch`
(0.1.0 is 100). It must increase with every Play upload.

## One-time setup (the maintainer runs these)

Requirements: Xcode (command line tools + full app), JDK 17, Gradle 8.14, Android SDK with
build-tools, [GitHub CLI](https://cli.github.com), an Apple Developer Program membership.

### 1. Android upload keystore

Keep the keystore **outside the repository** and back it up (password manager + offline copy).
Losing it means you cannot update the GitHub APK line.

```bash
mkdir -p ~/.panecast
keytool -genkeypair -v -keystore ~/.panecast/upload.jks \
  -alias panecast -keyalg RSA -keysize 4096 -validity 10000
```

Create `receiver/keystore.properties` (gitignored):

```properties
storeFile=/absolute/path/to/upload.jks
storePassword=<store password>
keyAlias=panecast
keyPassword=<key password>
```

Alternatively export `PANECAST_KEYSTORE`, `PANECAST_KEYSTORE_PASSWORD`, `PANECAST_KEY_ALIAS`,
`PANECAST_KEY_PASSWORD`. Without either, `assembleRelease` produces an **unsigned** APK with a
warning (it never falls back to the debug key) and `scripts/release-android.sh` refuses to run.

### 2. macOS Developer ID and notarization

1. In your Apple Developer account create a **Developer ID Application** certificate and install it in the login keychain.
   Check: `security find-identity -v -p codesigning | grep "Developer ID Application"`.
2. Store notarization credentials once (app-specific password from your Apple ID account page):

   ```bash
   xcrun notarytool store-credentials "panecast-notary" \
     --apple-id "<apple-id>" --team-id "<team-id>" --password "<app-specific-password>"
   ```
3. Copy `scripts/signing.local.sh.example` to `scripts/signing.local.sh` and fill in
   `RELEASE_IDENTITY` (certificate name or SHA-1 hash from step 1) and
   `NOTARY_PROFILE="panecast-notary"`. Without `NOTARY_PROFILE`, `release-macos.sh` still
   produces a signed build but prints a loud warning: it is **not notarized**, do not publish it.

## Release checklist

1. Set the new version in `VERSION` (e.g. `0.1.0`). Write the "What's new" text into a file (used as `RELEASE_CHANGES_FILE` below).
2. Clean checks:
   ```bash
   python3 scripts/scrub-personal-data.py --check --worktree
   (cd src/sender-macos && swift test)
   (cd receiver && gradle assembleDebug) && scripts/test-receiver-reorder.sh
   ```
3. Build everything:
   ```bash
   RELEASE_CHANGES_FILE=path/to/whats-new.md ./scripts/release-all.sh
   ```
   This runs `release-macos.sh` (universal arm64 + x86_64, hardened runtime, notarize, staple,
   dmg + zip) and `release-android.sh` (signed APK + AAB, `apksigner verify`), then writes
   `dist/SHA256SUMS.txt` and `dist/RELEASE_NOTES.md` from `docs/release-notes-template.md`.
4. Verify by hand before publishing:
   - `xcrun stapler validate dist/PaneCast-X.Y.Z-macOS.dmg`
   - `spctl -a -vv -t exec` on the app from the mounted dmg (expect "accepted", source "Notarized Developer ID")
   - `lipo -archs` on the app binary (expect `x86_64 arm64`)
   - Install the APK on a real Android TV and run a pairing + cast session; do a Mac cast with audio.
   - `dist/RELEASE_NOTES.md` says "notarized and stapled" for macOS; if it says "not notarized", fix the setup and rebuild.
5. Commit the version bump, tag, and push (maintainer action). Use a **lightweight** tag: the pre-push
   privacy audit reads every history object, and an annotated tag object carries its own tagger name and
   e-mail, so `git tag -a` gets the release rejected by this repository's own check.
   ```bash
   git tag v0.1.0
   git push origin main v0.1.0
   ```
6. Create the GitHub Release (maintainer action; add `--draft` to review first):
   ```bash
   gh release create v0.1.0 dist/* --title "PaneCast 0.1.0" --notes-file dist/RELEASE_NOTES.md
   ```
7. After publishing, download the assets from the release page and check them against `SHA256SUMS.txt`.

## Google Play (Android TV)

The AAB is `artifacts/play/PaneCast-Receiver-X.Y.Z.aab`. Notes:

- Play for TV needs the AAB, a **leanback launcher activity** and the `android.software.leanback`
  feature (both declared in the manifest), a TV banner (`banner.png`, present) and TV screenshots.
- Enrol in **Play App Signing**. You upload with the upload key; Google re-signs the APKs it serves with
  its own app-signing key.
- **Target API level:** the receiver declares `targetSdk = 34` (raised for the Android TV Play minimum in
  0.2.0). Verify the current Play requirement before each upload; raising it further (35+) means re-testing
  on a real TV, because the receiver only runs on API 30 hardware. This does not affect GitHub APKs.
- Play also needs a privacy policy URL and a Data safety form (PaneCast collects nothing; it has no
  account, cloud or telemetry).

### GitHub APK vs Play build: signing keys differ

- The GitHub APK is signed with your **upload key** (keystore above).
- The APK a user gets from Play is signed with the **Play app-signing key**.
- Android refuses to update an app when the signing certificate differs, so a user cannot update
  across the two channels: they must uninstall first, which also clears the stored pairing. Tell users
  to pick one channel.
- To make both channels share one key, Play lets you upload an existing signing key during
  App Signing enrolment (see the Play Console documentation for the current procedure). Decide this
  **before** the first Play upload, because the choice is made at enrolment.
- Keep the `applicationId` (`app.panecast.receiver`) identical on both channels.

## Not covered

- Windows sender: not available yet.
- Automatic updates: none (no update framework, no telemetry).
