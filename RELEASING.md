# Releasing

Packages are built by GitHub Actions, not on a laptop. The workflow is
[`.github/workflows/release.yml`](.github/workflows/release.yml); a `v*` tag builds and publishes,
`workflow_dispatch` only builds (artifacts, no release).

## What a release contains

| Asset | Built from | Notes |
|---|---|---|
| `synhub-<ver>-arm64.apk` | `scripts/build_arm64_release.sh` on `ubuntu-latest` | arm64-v8a only; signed with the project release key when the secret is present |
| `synhub-<ver>-web.tar.gz` | `flutter build web --release` | static bundle; serve it, or unzip and open `index.html` through a static server |
| `synhub_<ver>_<arch>.deb` | `scripts/build_linux_deb.sh` | x86_64 Debian/Ubuntu package |
| `SHA256SUMS.txt` | the three assets above | verify before installing; see § Verify |

Nothing here is signed by Synology, and none of it is notarized. macOS and Windows packages are
not produced yet — the macOS build is ad-hoc signed (Gatekeeper will complain) and the Windows
MSIX story needs its own decision.

## One-time setup: signing secrets

The Android release key lives **outside** the repository. To let Actions sign builds, add four
repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -i ~/keystores/synhub-release.jks \| pbcopy` (single line, no wrapping) |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | the key alias inside the keystore |
| `ANDROID_KEY_PASSWORD` | the key password (often the same as the keystore one) |

Generate the base64 yourself and paste it into the secret field — never commit the keystore, and
never paste it into an issue.

Without `ANDROID_KEYSTORE_BASE64` the workflow still runs: it warns loudly, produces a
**debug-signed** APK and marks it as such. Do not publish that one.

The same command that produces the base64 also lets you sanity-check the key locally:

```bash
keytool -list -v -keystore ~/keystores/synhub-release.jks | grep -E 'Alias|SHA256'
```

## Cutting a release

```bash
# 1. bump the version in pubspec.yaml, and add the CHANGELOG entry
# 2. land it through a PR (main is protected)
git checkout main && git pull
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0        # <-- this triggers the release workflow
```

The workflow builds the three assets, writes `SHA256SUMS.txt`, creates the release for the tag if
it does not exist, and uploads everything. Watch it under Actions → release.

If something fails, fix it on `main`, delete the tag, and re-tag — do not upload hand-built files
next to CI-built ones; the point is that every asset in a release names the commit it came from.

## Verify

```bash
sha256sum -c SHA256SUMS.txt

# Android: the certificate must be the project's release key, not a debug key
apksigner verify --print-certs synhub-<ver>-arm64.apk | head -3

# Linux
dpkg-deb -I synhub_<ver>_amd64.deb | head -20
```

The APK is signed with the project key. If you build the app yourself with your own key, Android
refuses to install it over a release build (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) — uninstall
first, which deletes app data and stored NAS credentials.

## Known limits of these builds

- **arm64-v8a only.** No 32-bit, no x86/x86_64 Android.
- The APK carries `lib/arm64-v8a/libsynochatpunch.so`, built from `reimpl/` for QuickConnect
  hole-punching. The workflow fails if that library is missing from the package.
- Web builds of encrypted-DSM write paths need same-origin deployment (see the README).
- These are cryptographic signatures of *build provenance*, nothing more: Synology does not
  endorse this client, and the app is unofficial.
