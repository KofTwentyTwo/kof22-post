# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it privately through GitHub's
[private vulnerability reporting](https://github.com/KofTwentyTwo/kof22-post/security/advisories/new)
(the repository's **Security** tab, then **Report a vulnerability**). That is the only
reporting channel.

Security contact: **James Maes** ([@KofTwentyTwo](https://github.com/KofTwentyTwo)),
maintainer.

Please include the affected version, how to reproduce it, and the impact you see.

## What to expect

KofTwentyTwo follows coordinated vulnerability disclosure. Timeframes are counted
from the day the report arrives and come from the
[KofTwentyTwo security program](https://github.com/KofTwentyTwo/standards/blob/main/policies/security-program.md):

| Step | Target |
| --- | --- |
| Acknowledge the report | 7 days |
| Assess it: confirm or reject, with a severity | 14 days |
| Release a fix for a CRITICAL vulnerability | 7 days |
| Release a fix for a HIGH vulnerability | 30 days |
| Release a fix for a MEDIUM vulnerability | 90 days |
| Release a fix for a LOW vulnerability | The next release |
| Publish the advisory (GitHub Security Advisory, CVE where applicable) | When the fix ships, or 90 days after the report, whichever comes first |

Reporters are credited in the advisory unless they ask not to be.

## Supported versions

| Version | Security fixes |
| --- | --- |
| Latest build of `main` (pre-release 0.x) | Yes |
| Anything older | No; install the latest build |

The app has not had a public release. Until it does, only the latest build from
`main` receives fixes. After the first release, only the latest minor release is
supported; a line ends when the next minor version is released.

## Published vulnerabilities

Fixed vulnerabilities are published as
[GitHub Security Advisories](https://github.com/KofTwentyTwo/kof22-post/security/advisories).
