# Third-party notices

This project is licensed under Apache-2.0 (see [LICENSE](LICENSE)). It links or vendors the
following third-party components; their licenses apply to those parts.

## Vendored source

| Component | Location | License |
|---|---|---|
| UDT4 (UDP-based Data Transfer) | `reimpl/third_party/udt4/` | BSD-3-Clause — Copyright (c) 2001-2011, The Board of Trustees of the University of Illinois. Full text: `reimpl/third_party/udt4/LICENSE.txt` |

## Dart / Flutter packages

The application depends on ~65 pub packages (see `pubspec.lock` for exact versions).
They are **not** vendored in this repository; each is fetched from pub.dev under its own
license (mostly BSD-3-Clause or MIT). To enumerate them:

```bash
flutter pub deps --style=compact
# or, after a build:
cat .dart_tool/package_config.json | grep '"name"'
```

Notable ones and their licenses:

| Package | License |
|---|---|
| `flutter`, `flutter_localizations` | BSD-3-Clause (Flutter Authors) |
| `dio`, `path`, `collection`, `crypto`, `intl` | BSD-3-Clause / MIT (Dart team) |
| `media_kit`, `media_kit_video`, `media_kit_libs_*` | MIT / LGPL-2.1+ for the bundled libmpv binaries (see upstream) |
| `flutter_gemma_litertlm` (on-device LLM) | MIT; bundles Google LiteRT-LM native assets under their own terms |
| `record`, `flutter_tts`, `local_auth`, `webview_flutter`, `open_filex` | BSD-3-Clause / MIT (per package) |
| `pdfx`, `printing`, `syncfusion_*` (if present in `pubspec.lock`) | per package; check `pubspec.lock` and the package page |

## Native platform components

| Component | Where | Notes |
|---|---|---|
| libmpv / FFmpeg media stack | shipped inside `media_kit` native assets at build time | LGPL/GPL depending on build flags; not vendored here |
| poppler (`pdftoppm`) | Linux runtime, system package | GPL-2.0 — invoked as an external binary, not linked |
| espeak-ng | Linux runtime, system package | GPL-3.0 — invoked as an external binary |

## Trademarks

"Synology", "DiskStation", "DSM", "QuickConnect", "File Station", "Synology Photos",
"Synology Chat", "Note Station", "Audio Station", "Synology Drive", "Download Station",
"Surveillance Station" are trademarks or registered trademarks of Synology Inc.
This project is not affiliated with Synology Inc.; the names are used only to describe
interoperability. No Synology binary, decompiled source, or copyrighted asset is included
in this repository.
