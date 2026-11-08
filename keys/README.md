# Package signing key

This is the GPG key that signs the Linux packages and the repository indexes:

```
key-fingerprint: 9E85497E64A128A1427CD5F8AEF0C14A16617FE8
key-created: 2026-11-09
key-algorithm: ed25519 (sign only)
key-uid: SynHub release signing <noreply@openviewai.com>
```

`synhub-archive-keyring.asc` in this directory is its **public** half. The private half exists only
as the `SYNHUB_GPG_PRIVATE_KEY` Actions secret and as an offline backup held by a maintainer — it is
never in this repository, and `scripts/new_gpg_key.sh` writes it to
`~/.config/synhub/synhub-linux-signing-key.asc` (`0600`) on the maintainer's machine.

## What it signs

| Artifact | Signature |
|---|---|
| `synhub-<ver>-1.<arch>.rpm` | embedded (verify with `rpm --checksig -v`) |
| `synhub_<ver>_<arch>.deb` | detached `.deb.asc` (verify with `gpg --verify`) |
| `SHA256SUMS.txt` | detached `SHA256SUMS.txt.asc` — covers **all six platforms**, including the macOS and Windows artifacts |
| apt `Release` / `InRelease` | detached / clearsigned |
| dnf `repodata/repomd.xml` | detached `repomd.xml.asc` |

Consequence worth stating plainly: the `.rpm` has an embedded signature because rpm supports one;
the `.deb` does not, because Ubuntu 24.04 dropped `dpkg-sig`, `debsigs` is broken there
(`--sign=archive` fails with a perl "uninitialized value" error, then `--verify` says
`no entry in archive`), and **apt never checks embedded deb signatures anyway** — it checks the
`Release`/`InRelease` signature. Detached signatures are therefore the honest option, and the
repository path is what actually gets verified by the package manager.

## Rotating the key

1. `scripts/new_gpg_key.sh` — new key, writes the private half outside the repo, updates this
   directory's public key, prints the new fingerprint.
2. Put the fingerprint into the `key-fingerprint:` line above (a CI step compares it against the
   secret and **fails the build** if they disagree, so the published repository can never be signed
   by a key that users do not have).
3. Store the private half as `SYNHUB_GPG_PRIVATE_KEY` and the fingerprint as `SYNHUB_GPG_KEY_ID`.
4. Old releases keep their old signatures; document the rotation in the release notes so users
   re-import the keyring.

## Verifying by hand

```bash
gpg --show-keys --with-fingerprint keys/synhub-archive-keyring.asc   # must print the fingerprint above
gpg --import keys/synhub-archive-keyring.asc
gpg --verify SHA256SUMS.txt.asc SHA256SUMS.txt
```
