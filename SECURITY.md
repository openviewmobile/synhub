# Security policy

## Reporting a vulnerability

Open a **private** security advisory on the GitHub repository
(Security → Advisories → "Report a vulnerability"), or email the maintainer listed in
the repository profile. Please do **not** open a public issue for a vulnerability.

Include: affected version/commit, platform, reproduction steps, and impact.

We aim to acknowledge within 7 days and to ship a fix or mitigation within 30 days
for issues that affect users' data or credentials.

## Scope

In scope:

- Credential handling (keystore / sandbox file storage, redaction in logs and UI strings);
- TLS trust decisions (pinning bypass, hostname verification);
- QuickConnect hole-punching and relay code in `reimpl/`;
- Any path where a malicious or compromised NAS could make the client execute or leak data.

Out of scope:

- Vulnerabilities in DSM itself, in Synology's servers, or in the official apps;
- Missing features;
- Issues that require a rooted/jailbroken device or physical access to an unlocked device.

## Please do not commit secrets

Never commit a NAS account, password, session id, `SynoToken`, keystore, or capture file
from a real NAS. Tests must run against `tool/mock_dsm/`. If you paste a command containing
`SYNO_NAS_PASSWORD=...` into an issue, rotate that password afterwards.

## Supported versions

Fixes land on `main`; there are no maintained release branches yet.
