# Roadmap

No dates. Something lands when it is **verifiable**, and this file is updated when that
happens — not when it is started. If an item here looks stale, open an issue and say so.

## Where the project is

Working, self-contained source for six targets. What CI actually proves today:

- `flutter analyze` + the full offline suite (~800 files) on every push and PR;
- dependency-vulnerability scan (OSV) on every push and PR;
- web / linux / windows / macos **really build** once a week;
- coverage is measured weekly but is deliberately **not** a merge gate.

What is *not* proven by anything in this repository: per-platform acceptance walkthroughs.
The upstream project keeps those ledgers (and thousands of screenshots) in a private QA
repository. Treat "builds" and "acceptance-tested" as different words.

## Now

- [ ] Keep the dependabot batch moving (currently: `go_router`, `archive`, `image`,
      `cupertino_icons`, `audio_session`).
- [x] Releases ship prebuilt packages for all six targets (`v0.2.0` onwards), built by CI from the
      tagged commit. See § [Packages](README.md#packages) for what each signature level means.
- [ ] Make the CI suite cheaper: 20+ minutes on a 4-core runner is the main reason people
      stop pushing. Sharding by directory is the obvious lever.

## Next

- [ ] **Platform smoke coverage in CI** for Android and iOS — today they are "local build
      only", so a broken Gradle or Podfile lands silently.
- [ ] **Architecture overview** for people who want to fork: how `lib/src/data/*` maps to
      DSM APIs, where the request/response layer lives, how the mock server is extended.
- [ ] **More locales.** Only `en` and `zh` exist; the ARB pipeline is already there.
- [ ] **Move the Windows job back to `windows-latest`** once `local_auth_windows` stops using
      `<experimental/coroutine>` (MSVC 14.5x rejects it; see `platform-build.yml`).
- [ ] **Web without the same-origin requirement** for encrypted-DSM write paths.

## Later

- [ ] MSIX packaging for Windows and a notarized macOS build — both need a certificate we do not
      have; today Windows ships a zip and macOS an ad-hoc signed app.
- [ ] Plugin/extension point for custom views over the file/photo APIs.
- [ ] Offline-first document editing (Office) — currently view + create, not collaborative edit.

## Known debt

### Build hooks fetch binaries from GitHub Releases — and that path breaks

Two dependencies compile native code through Dart build hooks that **download prebuilt
binaries from GitHub Releases at build time**, on every clean machine:

| package | what it fetches | where from |
| --- | --- | --- |
| `flutter_gemma_litertlm` 1.8.6 | `litertlm-<platform>.tar.gz` (7–98 MB) | `DenisovAV/flutter_gemma` |
| `sqlite3` 3.6.0 | `libsqlite3.<arch>.<os>.so` (~1.8 MB) | `simolus3/sqlite3.dart` |

``flutter test`` and `flutter build` both trigger them. That makes CI and release builds depend
on a third-party download, and in November 2026 that path stopped working: `DenisovAV/flutter_gemma`
was **renamed to `DenisovAV/flutter_edge_ai`**, after which `github.com/.../releases/download/...`
answers **HTTP 504** (not 404) for the old path — and, on this machine as well as on runners, for
the new one too. The hooks report it badly:

* `flutter_gemma_litertlm` exits 255 with `Unhandled exception … could not download litertlm
  native libs`, and the whole test step dies before running anything. No `[E]`, no failing test
  name — which is why CI looked like "failure count +1 but no failure printed" for several runs.
* `sqlite3` writes the error body into its cache file and then fails the **sha256 check**, which
  reads like upstream re-published the asset. It did not; the file's hash still matches the pin.

`tool/seed_native_libs.sh` pre-places both, fetched from the API asset endpoint
(`api.github.com/repos/<owner>/<repo>/releases/assets/<id>` with
`Accept: application/octet-stream`), which answered 200 while the `releases/download` path was
returning 504. It lays the files out the way each hook's own cache expects — including the JSON
marker the litertlm hook uses as its commit point — so the hooks resolve from cache and never
touch the network. Verified cold (5.7 s) and warm (instant); wired into `ci.yml` and
`platform-build.yml`.

This is debt, not a fix: the day either package bumps its version, the asset ids and cache layout
have to be re-checked. Checked wastefully, but silently-failing builds are worse.

- **The Windows package is 143 MB, and the size is a product decision, not a bug.**
  Measured from the published zip (377 MB unpacked): `openvino_intel_npu_compiler.dll`
  78 MB, `dxcompiler.dll` 17 MB, `openvino.dll` 15 MB, `webgpu_dawn.dll` 11 MB,
  `LiteRtWebGpuAccelerator.dll` 12 MB, `LiteRtTopKWebGpuSampler.dll` 9 MB. These are the
  on-device AI accelerators, and both are **reachable at runtime**:
  `flutter_gemma`'s `PreferredBackend.npu` is documented for Windows on Intel
  LunarLake/PantherLake, and `gpu` on any DX12-class adapter. Nothing statically imports
  them (the whole LiteRT stack is `LoadLibrary`-ed by the FFI layer), so deleting them
  produces a package that still launches — and silently loses NPU/GPU inference. Shipping
  a slim variant therefore needs a real Windows machine to prove the CPU fallback still
  answers, which nobody has done. Note that the `X.dll` / `libX.dll` pairs are **not**
  deletable duplicates either: both names appear in the other modules' import tables.
- **The Android APK is 111 MB**, of which ~45 MB is the on-device AI runtime
  (`libLiteRtLm.so` 26 MB + LiteRT accelerators/samplers ~19 MB).

## Not planned

| | Why |
|---|---|
| Synology account sign-in / QuickConnect ID *brokering* through a third party | The client must talk only to the NAS you configure. No relay of ours. |
| FCM or any push service | The app has no server component; notifications are local. |
| Telemetry or crash reporting to a third party | Analytics stay in an on-device SQLite file, see § Privacy in the README. |
| Bundling vendor code or decompiled sources | Clean-room only; see `CONTRIBUTING.md` ground rules. |
| 32-bit Android, x86/x86_64 Android | arm64-v8a only, by decision. |

## Good first issues

Small, self-contained, and each one ends in a test you can run offline:

- add a locale (copy `lib/l10n/app_en.arb`, run `flutter gen-l10n`, run the l10n tests);
- extend `tool/mock_dsm/` with a suite the mock does not answer yet — the test suite has
  plenty of places that would immediately exercise it;
- improve an error message that currently surfaces a raw DSM error code without a hint;
- add a widget test for a screen with no coverage.

If you want to claim one, open an issue first so two people do not write the same patch.
