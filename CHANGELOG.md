# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.

## [Unreleased]

### Changed
- Dependencies: `xml` 7, `open_filex` 5, `file_picker` 13.3.2, `flutter_lints` 6
  (490 mechanical lint fixes from `dart fix`), `actions/checkout` v7.
- `dynamic_color` stays on 1.x: 2.x pulls in the separate `material_ui` toolkit, whose
  `ColorScheme` is a different type from Flutter's.
- `drift` 2.35.3 with `web/drift_worker.dart.js` re-vendored from the matching release
  (the pinned wasm/worker pair cannot be bumped by a version PR alone).

### Added
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

[Unreleased]: https://github.com/openviewmobile/synhub/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/openviewmobile/synhub/releases/tag/v0.1.0
