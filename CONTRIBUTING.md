# Contributing

Thanks for helping! A few rules keep this project reviewable.

## Ground rules

1. **No real-NAS artifacts.** No screenshots from your own NAS, no capture files, no
   credentials, no `SynoToken`/`_sid` values. Tests must run against `tool/mock_dsm/`.
2. **No vendor code.** Do not paste decompiled Synology source, `.lib`/`.so` extracts, or
   strings dumps from vendor packages. Describe the protocol in your own words instead.
3. **Keep tests hermetic.** `flutter test` must pass with the network unplugged.
4. **One concern per PR.** Bug fix + refactor in the same PR is hard to review.

## Before you open a PR

```bash
flutter analyze lib test tool/mock_dsm     # must print "No issues found!"
flutter test                               # must be green, ~800 files
bash tool/secret_scan.sh                   # must be green
```

You can have the last one run automatically on every commit:

```bash
pipx install pre-commit   # or: uv tool install pre-commit
pre-commit install        # writes .git/hooks/pre-commit
```

The hook is defined in `.pre-commit-config.yaml` and only calls repo-local scripts
(`tool/secret_scan.sh`), so it runs the same check CI runs — the wordlist comes from
`SECRET_WORDS` in the environment or the gitignored `tool/secret_words.local`.

If you touch the UI strings, run `flutter gen-l10n` and commit both ARB files
(`lib/l10n/app_en.arb`, `lib/l10n/app_zh.arb`) — never hand-edit `lib/l10n/gen/`.

If you touch platform runners, add the exact command you used to verify the build
(e.g. `flutter build macos --debug`) to the PR description.

## Changing platform code

`flutter test` says nothing about whether a platform tree still compiles — it compiles
Dart, not the Swift/Kotlin/C++ runners. If you touch `macos/`, `ios/`, `windows/`,
`linux/`, `android/` or a conditional import, build that platform before opening the PR:

```bash
flutter build macos --debug     # macOS
flutter build linux --debug     # Linux
flutter build windows --debug   # Windows
flutter build web --release     # Web (catches dart:io leaking into shared code)
flutter build apk --debug --target-platform android-arm64
```

The `platform-build` workflow runs the web/linux/windows/macos builds weekly; it is not a
per-PR gate (a macOS build is expensive), so a green PR does not mean the platform compiles.

## When a test fails only in CI

Don't re-run until it goes green — that produces no information and leaves the suite
untrustworthy. Use the `flake-probe` workflow (Actions → flake-probe → Run workflow):

```
tests:  test/that_file_test.dart     # space-separated, several files allowed
repeat: 10                           # per file, on one runner
```

It runs each file that many times on the same Linux runner and prints a per-iteration
table plus the failing assertion tail. Three outcomes:

| Result | What it means | What to do |
|---|---|---|
| fails in every iteration | plain regression | fix it |
| fails in some iterations | real flake | find the timing/order dependency and fix it |
| never fails in N repeats | not reproduced | say so in the PR; do not claim it is fixed |

Last measurement (2026-11-06, Linux runner, one file at a time, 5 repeats each):

```
30/30 iterations green — media_stream, photo_p0_batch_ui, photo_p0_deadcode_coverage,
photo_p0_delete_quality, file_download_tasks, drive_admin_api_mock
3/3 green — the same six files in a single invocation, on macOS
```

Those six were carried as "known flaky" for a long time. They do **not** reproduce
isolated, which means any remaining flake lives in concurrency with the rest of the
suite, not in those files by themselves. If one of them goes red again, run the probe
with `repeat: 10` before touching the test.

## Commit messages

```
<area>: <what changed>

Why: <one or two sentences; the problem, not the diff>
Verified: <command(s) you ran and what you saw>
```

`<area>` is one of: `files`, `photos`, `chat`, `notes`, `audio`, `drive`, `download`,
`office`, `surveillance`, `admin`, `core`, `i18n`, `design`, `android`, `ios`, `macos`,
`linux`, `windows`, `web`, `reimpl`, `tooling`, `docs`.

## Reporting bugs

Use the issue template. Include: platform + version, whether the NAS is reachable
(QuickConnect vs direct), and the exact steps. **Redact** hosts, accounts, session ids and
file names before pasting logs.

## Security issues

Do not open a public issue — see [SECURITY.md](SECURITY.md).
