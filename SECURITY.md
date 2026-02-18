# Security Policy

Ghost Mail is a free and open-source iOS app for managing email aliases for Cloudflare-hosted domains.

## Supported Versions

Security fixes are provided for the latest released version on the App Store/TestFlight and the current `main` branch.

| Version / Channel | Supported |
| --- | --- |
| Latest App Store release | ✅ |
| Latest TestFlight build | ✅ |
| `main` branch | ✅ |
| Older releases | ❌ |

## Reporting a Vulnerability

Please **do not** open a public GitHub Issue for security-sensitive reports. Instead, report vulnerabilities privately.

### Preferred: GitHub private reporting
Use GitHub’s “Report a vulnerability” feature (Security → Advisories) for this repository. This keeps discussion private while we triage and coordinate a fix.

### What to include
- A clear description of the issue and potential impact (e.g., token exposure, unauthorized Cloudflare changes).
- Steps to reproduce (proof-of-concept preferred).
- Affected versions/builds and device/iOS version.
- Screenshots/logs only if they do not contain secrets.

### What to expect
- Initial acknowledgement within **72 hours**.
- Status update within **7 days** (or sooner if actively exploitable).
- If accepted, we’ll work on a fix and coordinate a release; if declined, we’ll explain why.

### Disclosure guidelines
- Please practice responsible disclosure: report privately first and allow reasonable time to fix before public disclosure.
- Do not test against accounts, domains, or data you do not own or have explicit permission to test.
- Do not include real secrets (Cloudflare API tokens, auth headers) in reports; redact them.

## Scope

In scope:
- The iOS app code in this repository.
- Handling/storage of credentials (e.g., Cloudflare API tokens), local data protection, and network/API interactions.

Out of scope:
- Cloudflare platform vulnerabilities (report those to Cloudflare).
- Vulnerabilities in third-party dependencies where no reasonable mitigation exists in this app.
- Social engineering, phishing, and physical-device-only attacks.
