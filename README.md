# SynHub

**Unofficial, from-scratch Flutter client for Synology NAS (DSM / DiskStation).**
Talks to DSM over its own Web API — QuickConnect, File Station, Photos, Chat, Note Station, Audio Station, Synology Drive, Download Station, Office suites, Surveillance Station and the DSM admin surface — on **Android, iOS, macOS, Linux, Windows and Web**.

> ⚠️ **Not affiliated with, endorsed by, or supported by Synology Inc.**
> "Synology", "DiskStation", "DSM" and the suite names are trademarks of Synology Inc.,
> used here only to describe what this client interoperates with.

> ⚠️ Use at your own risk. QuickConnect hole-punching is reimplemented from protocol
> observation; it may break whenever Synology changes their client.

---

## What this repository is (and is not)

| | |
|---|---|
| ✅ | Application source: Flutter/Dart (`lib/`), six platform runners, ~800 offline unit/widget tests, an offline mock DSM server (`tool/mock_dsm/`), and the clean-room QuickConnect hole-punch library (`reimpl/`) |
| ✅ | Build scripts for Android (arm64-v8a), iOS, macOS, Linux, Windows and Web |
| ❌ | **No prebuilt packages.** Source only — no APK / IPA / MSIX / deb / AppImage. Build it yourself (§ Build). |
| ❌ | **No screenshots or acceptance ledgers.** The upstream project keeps per-round acceptance evidence (thousands of screenshots, per-platform ledgers) in a private QA repository. Tests that assert on those ledgers are not shipped here. |
| ❌ | No credentials, no signing keys, no capture files from a real NAS. Anything that needs a server runs against the bundled mock. |

## Conventions

- Package id `com.openviewai.synhub`; Android target is **arm64-v8a only**.
- UI is bilingual (Simplified Chinese / English) via `flutter gen-l10n`; ARB files live in `lib/l10n/`.
- No FCM and no push service of ours — the app only talks to the NAS you configure.

## Getting the source

```bash
git clone https://github.com/openviewmobile/synhub.git
cd synhub
```

## Build

Prereqs: Flutter **3.47.x** (Dart 3.13), plus per platform:

| Target | Extra requirements |
|---|---|
| Android | JDK 17+, Android SDK; build the native hole-punch lib first (below) |
| iOS / macOS | Xcode 16+, CocoaPods |
| Linux | `clang cmake ninja-build pkg-config libgtk-3-dev`, `poppler-utils` (PDF), `espeak-ng` (TTS) |
| Windows | Visual Studio 2022 (Desktop C++), Windows 10+ |
| Web | Chrome; encrypted-DSM write paths need same-origin deployment |

> First run needs **network**: the `sqlite3` package downloads a prebuilt SQLite
> binary from GitHub; if that fails (flaky proxy/VPN), re-run `flutter pub get`/`flutter test`.
> Fully offline? Pre-seed `~/.pub-cache` on a machine that can reach GitHub.

```bash
flutter pub get
flutter gen-l10n

# Android: build the hole-punch library into jniLibs first (source in reimpl/)
bash reimpl/scripts/build_android.sh

flutter run -d <device>
# or
flutter build apk --release --target-platform=android-arm64
```

The Android release build **fails closed** without signing material: either set
`SYNHUB_KEYSTORE_FILE`, `SYNHUB_KEYSTORE_PASSWORD`, `SYNHUB_KEY_ALIAS`, `SYNHUB_KEY_PASSWORD`,
or create `android/key.properties` from `android/key.properties.example`.
Debug builds need nothing.

## Test

```bash
flutter analyze lib test tool/mock_dsm
flutter test                 # ~800 files, fully offline
```

Everything is hermetic: no test contacts a real NAS. Server-facing behaviour runs against
the in-tree mock:

```bash
dart run tool/mock_dsm/bin/serve.dart --port 18080 \
  --account mockuser --chat-demo --drive-demo --fs-demo --note-demo --photo-demo --download-demo
# account: mockuser / mockpass
```

Integration sweeps that drive a real desktop/web build live in `integration_test/` and need a
device (`flutter test integration_test/<file> -d macos`). They are not part of CI.

## Talking to a real NAS

Nothing in the repo contains credentials. Runtime settings are entered in-app and stored in the
OS keystore (or a `0600` sandbox file on desktop). For scripted probes, credentials come from
the environment:

```bash
export SYNO_NAS_URL=https://nas.example.com:5001
export SYNO_NAS_ACCOUNT=your_user
export SYNO_NAS_PASSWORD='...'     # never commit this
```

Self-signed certificates: the app pins the fingerprint you approve at first connect.

## Layout

```
lib/                     application (features/* core/* data/* design/* l10n/*)
android/ ios/ macos/ linux/ windows/ web/    platform runners
reimpl/                  clean-room C++ reimplementation of Chat hole-punching
tool/mock_dsm/           offline DSM mock server used by tests
tool/                    developer scripts
integration_test/        on-device sweeps (not run in CI)
test/                    offline test suite
assets/branding/         app icon sources
```

Comments in the code sometimes cite `docs/evidence-*/...` paths. Those are internal
acceptance records kept out of this repository; the references are provenance notes,
not files you can open here.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE) for third-party attributions and the trademark statement.
`reimpl/third_party/udt4` is third-party (BSD-style) and keeps its own headers.
