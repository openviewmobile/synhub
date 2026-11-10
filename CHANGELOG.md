# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.

## [Unreleased]

暂无。

### 发布说明与用户侧核验（未发版，随下一次发布生效）
- **发布说明现在先写“这一版改了什么”**：`scripts/changelog_section.py` 从 `CHANGELOG.md` 抽出本 tag 的小节，拼在资产表前面；抽不到只发警告、不编内容（发不出去比说明少一段更坏）。
- 新增 `scripts/verify_download.sh <目录>`：用**站点发布的公钥**建临时钥匙环，验 `SHA256SUMS.txt` 的签名、逐文件重算 sha256、再验 `.deb` 分离签名与 `.rpm` 嵌入签名；缺 `rpm` 会明说跳过而不是装作验过。反过来（把 deb 改一个字节）会明确报“与清单不一致”。

### CI（未发版，随下一次发布生效）
- `verify-release` 现在**每天 03:17 UTC 自动核一遍最新 release**（站点签名、apt/dnf 客户端、仓库字节）；没有给 tag 时会回落到“当前最新 release”，不再去核空版本号。
- 仓库字节的判据改为**签名索引里的 SHA256 == release 的**（重试 10 次）＋ **直链重取一次**（重试 6 次）；`apt-get download` 那一次抓取只作参考，不再单独定罪——r742 的假红就是它造成的。
- `release.yml` 的 android `verify` 与 `rpm-smoke.yml` 的 `rpm --checksig | grep -q` 改为先落盘再匹配：`grep -q` 命中即关管道 ⇒ 写端 SIGPIPE(141)，`pipefail` 会把“库在包里”判成失败（r741）。

## [0.2.8] - 2026-11-10

### Documented
- **No commercial code-signing certificates — recorded as a decision, not a backlog item.** macOS stays ad-hoc signed and Windows stays unsigned; the README now says what Gatekeeper and SmartScreen will show and the one gesture that gets past each, alongside the fact that the checksums and their GPG signature are what actually prove provenance. `RELEASING.md` says the same in the release table so a future round does not re-open it as 'pending work'.

## [0.2.7] - 2026-11-10

### Fixed
- **`v0.2.6` was cut without its version bump.** The `pubspec.yaml` / `kAppVersion` change was lost during a rebase, so the tag built and published **0.2.5** payloads under 0.2.6 names while the release notes described 0.2.6. The tag's notes now say so; `0.2.7` carries the same site change with the version actually bumped.

### Added
- `verify-release` now **waits for the published repository to catch up** before comparing bytes: GitHub Pages serves the previous deployment for a while after `gh-pages` is pushed, and a package whose file name is unchanged but whose bytes changed (`synhub_<ver>_amd64.deb`) is exactly the case where a hasty comparison reports a false mismatch.

## [0.2.6] - 2026-11-09

### Changed
- **The package site now has a page instead of an index.** `https://openviewmobile.github.io/synhub/` used to be three bare links ("signing key", "dnf repo file"); it now carries the apt and dnf install commands, the direct `.deb`/`.rpm` links, the `gpg --verify` + `sha256sum -c` steps, and an explicit note that the repository is x86_64-only and why. The version shown on the page and the file names in its table are read from the artifacts being published, so they cannot drift.

### Documented
- The `v0.2.2` and `v0.2.3` release notes now open with a warning that their `.rpm` cannot be verified by rpm 4.x (`dnf gpgcheck=1` will refuse it) and point at `v0.2.4` and later, which are signed inside an rpm 4.18 container and re-checked by the `verify-release` workflow.

## [0.2.5] - 2026-11-09

### Added
- **`verify-release` workflow** — after a release is published (or on demand via `workflow_dispatch` with a tag), it re-downloads the published assets and checks them the way a user would: every detached signature (`SHA256SUMS.txt.asc`, `SHA256SUMS.linux.txt.asc`, `*.deb.asc`) is verified with the public key fetched **from the published site** rather than the key that signed; each rpm's embedded signature is re-checked under `ubuntu:24.04` (rpm 4.18) and `fedora:41` (rpm 4.20) — the compatibility failure that shipped in `v0.2.2`/`v0.2.3`; a real `apt-get` client and a real `dnf` client install from the live repositories; and the deb/rpm the repositories serve must have the **same sha256** as the release assets.

### Documented
- **Linux arm64 is not buildable today, and the reason is external.** `flutter_action` on an `ubuntu-24.04-arm` runner fails with `Unable to determine Flutter version for channel: stable version: 3.47.4 architecture: arm64`, and the SDK release manifest (`releases_linux.json`) only ever lists `dart_sdk_arch: x64` — Flutter does not publish a Linux arm64 SDK, so there is nothing to build with. Cross-compiling the engine is out of scope. The apt index therefore stays `binary-amd64` and the rpm tree stays `x86_64`; ARM Linux users are better served by the Android build than by a broken repository entry. The release workflow keeps a single Linux job so this does not silently regress into a half-built repository.
## [0.2.4] - 2026-11-09

### Fixed
- **The `.rpm` was signed in a form rpm 4.x cannot read.** Packages from `v0.2.2`/`v0.2.3` report only digests under `rpm --checksig -v` on rpm 4.18/4.20 (Fedora ≤41, RHEL ≤9, openSUSE), while the runner's rpm 6.0.1 reports `Header OpenPGP V4 EdDSA/SHA512 signature … : OK` for the same file — so `dnf gpgcheck=1` on those systems would refuse the package. The rpm is now signed inside an `ubuntu:24.04` container (rpm 4.18), and the packaging smoke asserts that the signed package verifies under **both** rpm 4.18 and the runner's rpm 6.

## [0.2.3] - 2026-11-09

### Fixed
- **The `.rpm` shipped in `v0.2.2` had no verifiable signature.** `rpm --checksig -v` on the released file reports only digests, while re-signing the same file with the project key produces `Header V4 EdDSA/SHA512 Signature … : OK`. The signing step had judged success with `rpm --checksig | grep 'signatures OK'`, which is not the same statement as "this file carries a signature"; it now requires a `signature … : OK` line in the verbose output, and the publish job re-verifies with a fresh rpmdb built from the committed public key **before** uploading, failing the release if it does not hold.  The packaging smoke now builds a 40 MB payload so the signing path is exercised at release size rather than at 64 KB.

## [0.2.2] - 2026-11-09

### Changed
- `image` unpinned, `4.10.1` → `^4.12.0`, with `archive` `^4.0.7` → `^4.6.0`.

  The pin existed because `image` ≥ 4.11 calls `ZLibDecoder.decodeLazy`, which the locked
  `archive 4.0.9` did not have, and Linux/arm64 stopped compiling. The lock's `archive` is
  now 4.6.0 (decodeLazy landed in 4.1.0), so both ends move.

  The blocker was never the code — it was the guard. `DA285` asserted the literal string
  `4.10.1` in `pubspec.yaml`, so any upgrade failed it, and I previously misread two CI
  failures as a flaky widget test because the log tail showed the file that ran *next*. It
  is now the invariant it was trying to state: **if the locked `image` is ≥ 4.11, the locked
  `archive` must be ≥ 4.1.0**. Upgrades no longer need the guard edited; half-upgrades still
  go red.
- `audio_session` ^0.1.21 → ^0.2.4.
- Dropped `cupertino_icons`: nothing imports it (0 references in `lib/` and `test/`).
- `pubspec.lock` URLs normalised from the legacy `https://pub.dartlang.org` to
  `https://pub.dev` (a mechanical rewrite by the current pub client; no version changed).

### Fixed
- **CI's intermittent red had nothing to do with the tests.** Two build hooks download prebuilt
  binaries from GitHub Releases when `flutter test` runs; the `releases/download` path returns 504
  (one of the two repositories was renamed), and both hooks fail in ways that print no failing
  test at all — `flutter_gemma_litertlm` exits with an unhandled exception before the suite
  starts, `sqlite3` reports a bogus sha256 mismatch. `tool/seed_native_libs.sh` seeds both from
  the API asset endpoint (200 while the download path was 504), and the failure excerpt now goes
  to `$GITHUB_STEP_SUMMARY`, which is not truncated the way a 150k-line step log is.
- `lib/src/design/generated/` had drifted from its source: re-running
  `design/emit_flutter.py` over all 153 specs reproduced 150 files byte-for-byte and changed
  3 (`audio_radio`, `audio_song`, `media_player`) — someone had edited those specs without
  re-running the generator. Regenerated, so the checked-in pages are the spec again.
- The design specs carried real-hardware residue: a shipping phone's model string as the
  device name (`drive_connections`, `settings_profile`) and a private-range LAN address as
  the NFS mount (`file_mount`). Replaced with `SynHub demo unit` and
  `nas.example.com:/volume1/media` and regenerated (spec → SVG → Dart, with
  `design/check_parity.py` green). The removed values are deliberately not repeated here —
  writing them into prose to say they are gone is how they come back.

### Added
- **GPG-signed Linux artifacts and a signed package repository.** The `.rpm` now carries an
  embedded signature, the `.deb` ships a detached `.deb.asc`, and `SHA256SUMS.txt.asc` covers all
  six platforms. The publish job also builds apt (`Release`/`InRelease`) and dnf (`repodata`)
  indexes and pushes them to `gh-pages`, so Debian/Ubuntu and Fedora/RHEL/openSUSE can install and
  upgrade through their package manager with the index *and* the package verified
  (`repo_gpgcheck=1`). Key material lives in Actions secrets only; `keys/README.md` documents the
  fingerprint and rotation, and `build_linux_repo.sh` refuses to publish a repository whose signing
  key does not match the committed public key.
- **Build provenance attestations** for every released artifact
  (`actions/attest-build-provenance`), verifiable with `gh attestation verify <file> --repo
  openviewmobile/synhub`. This is not an OS signature — Gatekeeper and SmartScreen do not read it —
  but it proves an artifact came from this workflow at this commit.
- **Linux `.rpm`** next to the `.deb` (`scripts/build_linux_rpm.sh`, wired into `release.yml` as
  `synhub-<ver>-1.x86_64.rpm`). Same bundle, same layout: `/opt/synhub`, `/usr/bin/synhub`,
  desktop entry, icon, and a `%files` list that removes all four on `rpm -e`.
  Library dependencies are declared by **soname** (`libgtk-3.so.0`, `libsecret-1.so.0`,
  `libmpv.so.2`) because rpm's ELF dependency generator does not scan `/opt` — measured, not
  assumed: the same binary under `/usr/bin` produces requires, under `/opt` it produces none.
  `poppler-utils` is a `Suggests`: without it the app runs and PDF previews are blank.
  Guarded by a one-minute `rpm-smoke` workflow that packages a synthetic bundle on every change
  to the script.
- `ARCHITECTURE.md` — layer map, runtime spine, generated-code rules, and where to start
  reading. Numbers in it were measured from the tree.
- `.github/CODEOWNERS`, `.github/ISSUE_TEMPLATE/config.yml` (Discussions + private advisory
  links), `.mailmap`.
- `ROADMAP.md` § Known debt: the measured breakdown of the 143 MB Windows package and the
  111 MB APK — including the correction that the NPU/WebGPU DLLs are reachable
  (`PreferredBackend.npu` is documented for Windows on Intel LunarLake/PantherLake), so
  removing them is a product trade-off, not dead weight.

## [0.2.1] - 2026-11-07

Packaging fix-up for the first release. `v0.2.0` shipped a 311 MB macOS image and a
143 MB Windows zip because both included debug symbols.

### Fixed
- macOS `.dmg` is built from a staging directory holding only the `.app` (plus an
  `/Applications` symlink). Previously `dirname "$APP"` was used as the source, which
  swept the sibling `*.dSYM` bundle into the image — 311 MB instead of 53 MB.
- Windows `.zip` drops `*.pdb` files before archiving.

### Notes
- The Android APK is 111 MB. The breakdown, measured from the published asset:
  `libapp.so` 29.8 MB, `libLiteRtLm.so` 26.4 MB (on-device AI runtime), `libmpv.so`
  12.4 MB, `libflutter.so` 11.7 MB, LiteRT accelerators/samplers ~13 MB, QNN
  system+stubs ~11 MB, `classes.dex` 4.6 MB. Nothing here is accidental; the AI
  runtime is the largest single contributor.

## [0.2.0] - 2026-11-07

First release with packages. Every asset is built by
[`release.yml`](.github/workflows/release.yml) on GitHub-hosted runners from the tagged commit.

### Added
- **Prebuilt packages for all six targets**: Android arm64-v8a APK, unsigned iOS `.ipa`,
  ad-hoc-signed macOS `.zip` / `.dmg`, Windows x64 `.zip`, Linux `.deb` + `.tar.gz`, and the Web
  bundle, all with `SHA256SUMS.txt`. Signing levels are stated per asset rather than implied; see
  § Packages in the README and [RELEASING.md](RELEASING.md).
- `src/reimpl`-built hole-punch libraries are now compiled in CI before packaging — the Android job
  fails outright if `lib/arm64-v8a/libsynochatpunch.so` is missing, and the iOS job builds the
  static library the Runner link step requires.

### Notes
### Known CI flake (still unexplained)

`test/photo_album_write_test.dart` → "相册里的大图页有「设为封面 / 移出相册」" has now failed
**three times in CI** (v0.2.0 landing, v0.2.0 re-tag, and the readiness batch), always inside
`pumpWidget` at line 814, while passing on demand locally (3/3, 3/3 at the same commits).
It is recorded, not diagnosed. `test/file_mount_ui_test.dart` also appears in the same tail
of the log; whether it is a second failure or just the next running file has not been
established.

- One CI-only failure was observed while landing this release:
  `test/photo_album_write_test.dart` → "相册里的大图页有「设为封面 / 移出相册」" failed
  inside `pumpWidget` on `ubuntu-latest`, and passed 3/3 locally at the same commit. It is
  recorded here rather than called fixed — the cause is not established.

### Fixed
- `scripts/build_linux_deb.sh` hardcoded the arm64 bundle path, so it could not package an x64
  build. It now derives the bundle directory from `uname -m`.
- `scripts/build_arm64_release.sh` looked for `apksigner` only under `$HOME/Library/Android/sdk`.
  On Linux that empty substitution aborted the script under `set -e`, turning a successful build
  into a failure; the lookup now checks `command -v`, `ANDROID_HOME` and `ANDROID_SDK_ROOT`.

## Before the first tagged release

Work that landed before `v0.1.0`/`v0.2.0` and was never given its own
version section — kept here instead of pretending it shipped in one.

### Changed
- Dependencies: `xml` 7, `open_filex` 5, `file_picker` 13.3.2, `flutter_lints` 6
  (490 mechanical lint fixes from `dart fix`), `actions/checkout` v7.
- `dynamic_color` stays on 1.x: 2.x pulls in the separate `material_ui` toolkit, whose
  `ColorScheme` is a different type from Flutter's.
- `drift` 2.35.3 with `web/drift_worker.dart.js` re-vendored from the matching release
  (the pinned wasm/worker pair cannot be bumped by a version PR alone).

### Added
- `ROADMAP.md`: what is being worked on, what is deliberately not planned, and small
  self-contained starting points for contributors.
- README restructured: badges, an offline quick start, a per-suite table, an honest
  "builds vs acceptance-tested" platform table, the Linux dev packages that the build actually
  needs, a privacy section, and a table of what each CI workflow does.
- `.editorconfig` for cross-editor consistency.
- Branch protection on `main`: PR required, `ci / analyze-test` must pass, admins included.
- CI: a separate `supply-chain` job running OSV-Scanner over the lockfile.
- `coverage` workflow (weekly + manual, **not** a merge gate): line coverage in the job
  summary plus a `coverage-lcov` artifact. Kept off the PR path because `--coverage` takes
  the same suite from ~20 to ~36 minutes and turns timing-sensitive tests into noise.
- `.pre-commit-config.yaml` with a local `secret-scan` hook, so the wordlist scan runs before
  the push instead of only in CI.
- `flake-probe` workflow (manual, repeats chosen files N times on one Linux runner) and a
  CONTRIBUTING section on how to read its result instead of re-running until green.
- `ci` test step now keeps the full log in a file and prints only the tail plus the failing
  assertion lines: GitHub truncates an oversized step log from the **middle**, which is where
  the failure reason sits (a 23-minute red had to be re-derived from a widget-tree dump).
- `platform-build` workflow (weekly + manual): actually builds web / linux / windows / macos.
  Until now nothing in CI compiled a platform, so a broken platform tree could sit green —
  that is exactly how the macOS target stopped building unnoticed for a stretch.

## [0.1.0] - 2026-11-05

First public source release. Source only — no APK / IPA / MSIX / deb / AppImage.

### Added
- First public source release (no binary packages).
- Six platform runners: Android (arm64-v8a), iOS, macOS, Linux, Windows, Web.
- DSM client coverage: QuickConnect reimplementation (`reimpl/`), File Station, Synology Photos,
  Synology Chat, Note Station, Audio Station, Synology Drive, Download Station, Office
  document/sheet/slides viewers, Surveillance Station, and the DSM admin surface.
- Offline mock DSM server (`tool/mock_dsm/`) used by the test suite; no test needs a real NAS.
- Bilingual UI (Simplified Chinese / English) generated from ARB files via `flutter gen-l10n`.
- Android release signing is fail-closed: build refuses to produce a release APK without
  `SYNHUB_KEYSTORE_*` (or `android/key.properties`).

### Security
- No credentials, session ids, or signing material are stored in the repository.
- `tool/secret_scan.sh` runs in CI and blocks pushes containing secrets, private IPs of the
  original author's NAS, or private keys.

### Known limitations
- No prebuilt packages; you build from source.
- Web builds that write through encrypted DSM endpoints need a same-origin deployment.
- QuickConnect depends on Synology's client behaviour and may break on their updates.

[Unreleased]: https://github.com/openviewmobile/synhub/compare/v0.2.8...HEAD
[0.2.8]: https://github.com/openviewmobile/synhub/releases/tag/v0.2.8
[0.2.7]: https://github.com/openviewmobile/synhub/releases/tag/v0.2.7
[0.2.6]: https://github.com/openviewmobile/synhub/releases/tag/v0.2.6
[0.2.5]: https://github.com/openviewmobile/synhub/releases/tag/v0.2.5
[0.2.4]: https://github.com/openviewmobile/synhub/releases/tag/v0.2.4
[0.2.3]: https://github.com/openviewmobile/synhub/releases/tag/v0.2.3
[0.2.2]: https://github.com/openviewmobile/synhub/releases/tag/v0.2.2
[0.2.1]: https://github.com/openviewmobile/synhub/releases/tag/v0.2.1
[0.1.0]: https://github.com/openviewmobile/synhub/releases/tag/v0.1.0
