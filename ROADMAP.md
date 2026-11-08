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
