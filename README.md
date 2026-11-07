# SynHub

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.47.x-02569B.svg?logo=flutter)](https://flutter.dev)
[![Platforms](https://img.shields.io/badge/platforms-Android%20%C2%B7%20iOS%20%C2%B7%20macOS%20%C2%B7%20Linux%20%C2%B7%20Windows%20%C2%B7%20Web-lightgrey.svg)](#platform-status)
[![CI](https://github.com/openviewmobile/synhub/actions/workflows/ci.yml/badge.svg)](https://github.com/openviewmobile/synhub/actions/workflows/ci.yml)

**An unofficial, from-scratch Flutter client for Synology NAS (DSM / DiskStation).**

It speaks DSM's own Web API rather than wrapping an official app: QuickConnect hole-punching,
File Station, Photos, Chat, Note Station, Audio Station, Synology Drive, Download Station,
the Office suites, Surveillance Station and the DSM admin surface — on **Android, iOS, macOS,
Linux, Windows and Web**.

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
| ❌ | **No prebuilt packages.** Source only — no APK / IPA / MSIX / deb / AppImage. Build it yourself (§ [Build](#build)). |
| ❌ | **No screenshots or acceptance ledgers.** The upstream project keeps per-round acceptance evidence (thousands of screenshots, per-platform ledgers) in a private QA repository. Tests that assert on those ledgers are not shipped here. |
| ❌ | No credentials, no signing keys, no capture files from a real NAS. Anything that needs a server runs against the bundled mock. |

## Conventions

- Package id `com.openviewai.synhub`; the Android target is **arm64-v8a only**.
- UI is bilingual (Simplified Chinese / English) via `flutter gen-l10n`; ARB files live in `lib/l10n/`.
- No FCM, no push service of ours: the app only talks to the NAS you configure.
- Where a platform or server cannot do something, the UI **fails closed and says why** rather
  than showing a control that does nothing (`capabilityGateAllows()` in `lib/src/core/`).

## Quick start (offline — no NAS required)

The fastest way to see the app run is against the in-tree mock server. Nothing below needs
a real NAS or network access.

```bash
git clone https://github.com/openviewmobile/synhub.git
cd synhub
flutter pub get
flutter gen-l10n

# terminal 1 — mock DSM on http://127.0.0.1:18080 (account: mockuser / mockpass)
dart run tool/mock_dsm/bin/serve.dart --port 18080 \
  --account mockuser --chat-demo --drive-demo --fs-demo --note-demo --photo-demo --download-demo

# terminal 2 — run the app, then log in to http://127.0.0.1:18080 with mockuser / mockpass
flutter run -d <device>
```

Two developer-only screens (design gallery, diagnostics) are compiled out of release builds.
To get them back:

```bash
flutter run --dart-define=SYNHUB_DEV_TOOLS=true
```

## Suites covered

Each suite is implemented against DSM's own Web API — method/version tables cross-checked
against the official packages — not by scraping a UI.

| Suite | What the client does |
|---|---|
| File Station | browse, upload/download, rename/move/copy/delete, recycle bin, shares, archive & extract, thumbnails |
| Photos | timeline, albums, favourites, people/scenes, viewer, upload, batch actions |
| Chat | channels, messages, attachments, reactions, media streaming |
| Note Station | notebooks, notes, editor, tags, drawing, attachments |
| Audio Station | library, albums/artists, playlists, radio, queue, lyrics, equalizer where the host has one |
| Synology Drive | browse, upload/download, star, versions, sharing, admin surface (gated by identity) |
| Download Station | tasks, RSS feeds/filters, BT search, eMule where the server enables it |
| Office | document/sheet/slides viewers, template library, create (including encrypted) |
| Surveillance Station | cameras, live view, recordings |
| DSM admin | users, packages, services, logs — shown only to an admin session |
| MailPlus / Calendar / Contacts | list and detail views over their Web APIs |
| On-device AI | local model inference when the device meets the app's hardware threshold; never required, every AI screen works without it |

## Platform status

All six targets are buildable. "Builds" is not "acceptance-tested" — the per-platform
walkthrough ledgers and their screenshots are internal, so this table only claims what CI can
prove.

| Target | Proof | Notes |
|---|---|---|
| macOS, Linux, Windows, Web | built weekly by [`platform-build`](.github/workflows/platform-build.yml) | also runnable on demand |
| Android (arm64-v8a) | local build only | needs JDK 17+, Android SDK, and the native hole-punch library |
| iOS | local build only | needs Xcode + CocoaPods |

## Build

Prerequisites: Flutter **3.47.x** (Dart 3.13), plus per platform:

| Target | Extra requirements |
|---|---|
| Android | JDK 17+, Android SDK; build the native hole-punch lib first (below) |
| iOS / macOS | Xcode 16+, CocoaPods |
| Linux | `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libsecret-1-dev libmpv-dev libepoxy-dev poppler-utils espeak-ng` |
| Windows | Visual Studio 2022 (Desktop C++) with MSVC ≤ 14.4x, Windows 10+ |
| Web | Chrome; encrypted-DSM write paths need same-origin deployment |

```bash
flutter pub get
flutter gen-l10n

# Android: build the hole-punch library into jniLibs first (source in reimpl/)
bash reimpl/scripts/build_android.sh

flutter build apk --release --target-platform=android-arm64
# or, for any other target:
flutter build macos --debug
```

The Android release build **fails closed** without signing material: either set
`SYNHUB_KEYSTORE_FILE`, `SYNHUB_KEYSTORE_PASSWORD`, `SYNHUB_KEY_ALIAS`, `SYNHUB_KEY_PASSWORD`,
or create `android/key.properties` from `android/key.properties.example`.
Debug builds need nothing.

> First run needs **network**: the `sqlite3` package downloads a prebuilt SQLite
> binary from GitHub; if that fails (flaky proxy/VPN), re-run `flutter pub get`/`flutter test`.
> Fully offline? Pre-seed `~/.pub-cache` on a machine that can reach GitHub.

## Test

```bash
flutter analyze lib test tool/mock_dsm
flutter test                 # 798 files, fully offline
```

Everything is hermetic: no test contacts a real NAS. Server-facing behaviour runs against
the in-tree mock (see § [Quick start](#quick-start-offline--no-nas-required)).

Integration sweeps that drive a real desktop/web build live in `integration_test/` and need a
device (`flutter test integration_test/<file> -d macos`). They are not part of CI.

If a test goes red only in CI, do not re-run until it turns green — see
[CONTRIBUTING](CONTRIBUTING.md#when-a-test-fails-only-in-ci) for the `flake-probe` workflow
that repeats one file N times and tells you whether it is a regression or a flake.

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

## Privacy

- Usage analytics are **local only**: events are written to an on-device SQLite database, the
  account is stored as a salted hash, and file names, titles and note bodies are never recorded.
  The switch lives in Settings and defaults to on because nothing leaves the machine.
- No crash reporter, no push service, no third-party SDK that phones home.
- Credentials go to the OS keystore (desktop: a `0600` file inside the app sandbox).

## Layout

```
lib/                     application (features/* core/* data/* design/* l10n/*)
android/ ios/ macos/ linux/ windows/ web/    platform runners
reimpl/                  clean-room C++ reimplementation of Chat hole-punching
tool/mock_dsm/           offline DSM mock server used by tests
tool/                    developer scripts
integration_test/        on-device sweeps (not run in CI)
test/                    offline test suite (798 files)
assets/branding/         app icon sources
```

Comments in the code sometimes cite `docs/evidence-*/...` paths. Those are internal
acceptance records kept out of this repository; the references are provenance notes,
not files you can open here.

## Continuous integration

| Workflow | Trigger | What it does |
|---|---|---|
| [`ci`](.github/workflows/ci.yml) | every push / PR | analyze, the full test suite, a wordlist secret scan, and OSV dependency-vulnerability scanning |
| [`platform-build`](.github/workflows/platform-build.yml) | weekly + manual | really builds web / linux / windows / macos |
| [`coverage`](.github/workflows/coverage.yml) | weekly + manual | line coverage in the job summary, LCOV artifact. **Not** a merge gate |
| [`flake-probe`](.github/workflows/flake-probe.yml) | manual | repeats chosen test files N times on one runner |

`main` is protected: changes arrive through a pull request and `ci / analyze-test` must pass.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — ground rules (no real-NAS artifacts, no vendor code),
the pre-PR checklist, the pre-commit hook, and how to triage a CI-only failure.
Security issues: [SECURITY.md](SECURITY.md) (private advisory, please).
Changes per release: [CHANGELOG.md](CHANGELOG.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE) for the full text, [NOTICE](NOTICE) for the trademark
statement, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled third-party code.
`reimpl/third_party/udt4` is third-party (BSD-style) and keeps its own headers.
