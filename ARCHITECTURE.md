# Architecture

A map of the code, not a tutorial. Every number below was measured from the tree
(`find lib -name '*.dart' | wc -l` → **971** files, **509,634** lines at the time of
writing); if it drifts, the map is wrong and should be fixed.

The one-sentence version: **a Riverpod + go_router Flutter app whose only I/O is the
DSM Web API** — everything else (state, storage, playback, AI) is local and replaceable.

---

## 1. Layers

```
lib/
├── main.dart              entry point: bindings, ProviderScope, runApp
├── l10n/                  ARB sources + generated localisations (committed)
└── src/
    ├── app.dart           MaterialApp.router wiring
    ├── core/              97 files — cross-cutting infrastructure
    ├── data/             120 files — one client per DSM API family
    ├── dsm/                2 files — the API envelope (endpoint/version/error codes)
    ├── native/             4 files — platform channel bridge declarations
    ├── quickconnect/       2 files — hole-punch / relay client (see `reimpl/`)
    ├── design/            generated UI from `design/spec/*.json` (do not hand-edit)
    └── features/          27 feature folders — screens, widgets, controllers
```

Dependency direction is **one way**: `features → data → dsm`, with `core` available to
all of them. `features/` never imports another feature's internals; shared widgets live
in `features/widgets/` and shared plumbing in `core/`.

### `core/` — infrastructure

| Area | Directory | What lives there |
|---|---|---|
| Networking | `core/net/` | `dio_factory.dart` (timeouts, TLS policy hooks), `cert_policy_hook.dart`, `trust_store.dart`, traffic accounting |
| Errors | `core/user_facing_error.dart` | the single place that turns a thrown object into a sentence a user can read |
| JSON | `core/json_coerce.dart` | lenient readers (`jsonInt`/`jsonStr`/`jsonMapList`) — **never** bare `as num?` on server responses |
| Entitlement | `core/entitlement/` | `AppPrivilege` / session capability model; gates UI per account |
| Router | `core/router/app_router.dart` | the one `GoRouter` instance |
| Storage | `core/settings/`, `core/security/` | preferences; credentials go to the OS keystore (desktop: a `0600` sandbox file) |
| Platform | `core/platform/`, `core/device/` | capability probes (video decoder, TTS, AI accelerator), synthetic device profiles for tests |
| Observability | `core/log.dart`, `core/dev/` | redacting logger; diagnostics screens |

### `data/` — one file (or family) per API surface

`drive_api.dart`, `chat_api.dart`, `calendar_api.dart`, `download_station.dart`,
`audio_station.dart`, `note_api.dart`, `office_api.dart` (+ `office_collab/`, `office_native/`),
plus `dto/` for the shapes that cross module boundaries and `e2ee/` for the encrypted-chat path.
Photo browsing lives under `lib/src/features/photos/` with its own API client, because the
C2 endpoints are 4-wide-typed and were easier to keep beside the screens.

Rules that hold across `data/`:

- **Every call goes through `dsm/webapi.dart`**, which owns the `api`/`method`/`version`
  triple and the `SYNO.API` envelope. Nothing hand-builds a URL.
- Version selection is per method, not per app — see `tool/mock_dsm/observed_method_versions.json`
  for what a real DSM answers, and `test/api_version_guard_test.dart` for the static guard.
- Server responses are read with the lenient helpers in `core/json_coerce.dart`.

### `features/` — 27 folders, largest first

```
files 104 · photos 79 · notes 63 · drive 55 · chat 55 · office 37 · media 36
audio 31 · downloads 21 · ai 16 · … (admin, calendar, contacts, home, login,
mailplus, notifications, search, security, servers, settings, shell,
surveillance, widgets, analytics, diagnostics, design)
```

Each folder follows the same shape: `*_page.dart` (screen), `*_providers.dart`
(Riverpod controllers/notifiers), `*_widgets.dart` (local widgets). Features do not
talk to each other directly; they go through `data/` or a provider exposed by `core/`.

---

## 2. Runtime spine

```
main.dart
  └─ ProviderScope
       └─ app.dart → MaterialApp.router(routerConfig: appRouter)
            └─ feature page
                 └─ ref.watch(<feature>Provider)
                      └─ <XxxApi>            (lib/src/data/…)
                           └─ DsmWebApi      (lib/src/dsm/webapi.dart)
                                └─ Dio       (lib/src/core/net/dio_factory.dart)
                                     └─ DSM (https, QuickConnect or direct host)
```

Everything stateful is a Riverpod provider. Two conventions worth knowing before editing:

- **`autoDispose` providers must not be read from an async callback after the widget may
  have gone** — the container can dispose them mid-await. Use `ref.mounted` or hold the
  notifier.
- Long-lived singletons (session, task queues, playback) sit in `core/services/` and are
  deliberately **not** auto-disposed.

---

## 3. QuickConnect and the native hole-punch library

`lib/src/quickconnect/` is the Dart side; `reimpl/` is the clean-room C library that
implements the relay/hole-punch transport and is linked as a native library
(`libsynochatpunch`). It is built by `reimpl/scripts/build_android.sh` (NDK) and
`reimpl/scripts/build_ios.sh [--sim|--device]`, and both the release workflow and the
platform builds call those scripts — the `.so`/`.a` is **not** committed.

---

## 4. Testing surfaces

| Surface | Location | Scale | Runs in CI |
|---|---|---|---|
| Offline unit/widget tests | `test/` | ~800 files | ✅ every push/PR |
| Offline mock DSM server | `tool/mock_dsm/` | catalogue of api/method/version triples | via the tests |
| Offline mock NAS (HTTPS, files, TLS) | `tool/mock_nas/` | self-signed cert, throwaway key | manual |
| On-device walkthroughs | `integration_test/` | 83 files | ❌ manual only |

The split matters: CI proves the Dart layer against a mock; it does **not** prove any
real device, real DSM version, or real network path. Those live in private ledgers and are
not reproducible from this repository alone.

---

## 5. Generated code — never hand-edit

| Generated | From | Regenerate |
|---|---|---|
| `lib/l10n/gen/*.dart` | `lib/l10n/*.arb` | `flutter gen-l10n` |
| `lib/src/design/generated/*.dart` | `design/spec/*.json` | `python3 design/emit_flutter.py` |
| `web/sqlite3.wasm`, `web/drift_worker.dart.js` | pinned drift/sqlite3 releases | see the header of `test/web_assets_version_test.dart` |

There are guards that fail when a generated file drifts from its source
(`test/web_assets_version_test.dart` compares bytes and hashes).

---

## 6. Where to start reading

- Entry and wiring: `lib/main.dart` → `lib/src/app.dart` → `lib/src/core/router/app_router.dart`
- The API contract: `lib/src/dsm/webapi.dart`, then any `lib/src/data/*_api.dart`
- One complete vertical slice: `lib/src/features/files/` (largest feature)
- How a response becomes a sentence: `lib/src/core/user_facing_error.dart`
