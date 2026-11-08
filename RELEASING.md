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
| `synhub-<ver>-1.<arch>.rpm` | `scripts/build_linux_rpm.sh` | x86_64 Fedora/RHEL/openSUSE package |
| `synhub-<ver>-macos-<arch>.zip` / `.dmg` | `flutter build macos --release` | ad-hoc signed (Gatekeeper will complain) |
| `synhub-<ver>-windows-x64.zip` | `flutter build windows --release` | unsigned; MSIX is still an open decision |
| `SHA256SUMS.txt` | everything above | verify before installing; see § Verify |

Nothing here is signed by Synology, and none of it is notarized. The `.deb` and the `.rpm` are
the same bundle with two package wrappers: both install to `/opt/synhub` with a menu entry, a
`/usr/bin/synhub` launcher and an icon, and both uninstall cleanly.

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

## Signing the Linux artifacts and the package repositories

The `.deb`/`.rpm` and the apt/dnf indexes are signed with a project GPG key. Two repository
secrets drive it:

| Secret | Value |
|---|---|
| `SYNHUB_GPG_PRIVATE_KEY` | the armored private key (`gpg --armor --export-secret-keys <fpr>`) |
| `SYNHUB_GPG_KEY_ID` | the fingerprint, e.g. `9E85497E64A128A1427CD5F8AEF0C14A16617FE8` |

Generate or rotate the key with `scripts/new_gpg_key.sh` — it writes the private half **outside** the
repository (`~/.config/synhub/synhub-linux-signing-key.asc`, `0600`), updates
`keys/synhub-archive-keyring.asc`, and prints the two `gh secret set` commands. Keep an offline
backup: losing the key means rotating it, and every user has to import the new public key.

What gets signed, and by what:

| Artifact | Signature |
|---|---|
| `.rpm` | embedded (`rpm --checksig -v`) |
| `.deb` | detached `.deb.asc` — Ubuntu 24.04 dropped `dpkg-sig` and `debsigs` is broken there; apt verifies `Release`/`InRelease` anyway |
| `SHA256SUMS.txt` | detached `SHA256SUMS.txt.asc`, covering all six platforms |
| apt `Release` / `InRelease`, dnf `repodata/repomd.xml` | detached / clearsigned |

The publish job also builds both repositories and force-pushes them to the `gh-pages` branch, so
`https://openviewmobile.github.io/synhub/` is the stable base URL for `apt`/`dnf`. **GitHub Pages
must be enabled once** (Settings → Pages → Deploy from a branch → `gh-pages` / `/`); the job cannot
turn it on itself.

If the secrets are absent, the signing step prints a `::warning::` and skips, and the repository
step is skipped too — releases still happen, they are just unsigned and have no repository. The
`packaging-smoke` workflow covers the scripts themselves with a throwaway key on every change, so a
broken spec/index/signature path goes red without waiting for a tag.

A guard is worth knowing about: `build_linux_repo.sh` compares the fingerprint it actually signed
with the `key-fingerprint:` line in `keys/README.md` and **fails** if they differ. Publishing a
repository signed by a key users do not have would be worse than publishing none.

## Verify

```bash
sha256sum -c SHA256SUMS.txt

# Android: the certificate must be the project's release key, not a debug key
apksigner verify --print-certs synhub-<ver>-arm64.apk | head -3

# Linux — Debian/Ubuntu
dpkg-deb -I synhub_<ver>_amd64.deb | head -20
sudo dpkg -i synhub_<ver>_amd64.deb

# Linux — Fedora/RHEL/openSUSE
rpm -qip synhub-<ver>-1.x86_64.rpm
rpm -qpR synhub-<ver>-1.x86_64.rpm     # library deps, by soname
sudo dnf install ./synhub-<ver>-1.x86_64.rpm   # or: sudo rpm -Uvh ...
```

The rpm declares its library dependencies by **soname** (`libgtk-3.so.0`, `libsecret-1.so.0`,
`libmpv.so.2`) rather than by package name, because the package names differ between Fedora,
RHEL and openSUSE — and because `mpv-libs` on Fedora lives in RPM Fusion, which would otherwise
turn "install SynHub" into "add a third-party repository first". `poppler-utils` is a
`Suggests`: without it the app runs, but PDF previews render nothing.

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
