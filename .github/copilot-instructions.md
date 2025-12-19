# Copilot Instructions for Ghost Mail iOS

## Quick summary
Ghost Mail is a SwiftUI-first iOS app that manages Cloudflare Email Routing aliases. Key responsibilities are: UI (SwiftUI views under `ghostmail/Views/`), Cloudflare API orchestration (`ghostmail/Services/CloudflareClient.swift`), local persistence (SwiftData models under `ghostmail/Models/`), and secure credential storage via Keychain (`KeychainHelper.swift`).

## Architecture & important conventions
- **SwiftUI + SwiftData (CloudKit optional):** The app uses SwiftUI for UI and SwiftData for persistence. CloudKit mirroring is enabled by default (`iCloudSyncEnabled` AppStorage). See `ghostmailApp.swift` for ModelContainer initialization and the CloudKit schema (`EmailAlias` schema is explicitly constructed when sync is enabled).
- **Single source for Cloudflare logic:** `CloudflareClient` handles all Cloudflare interactions (pagination, token verification, multi-zone support, caching). Add/modify API interactions there and expose behavior via `@EnvironmentObject`.
- **Multi-zone support & token storage:** Zones are represented by `CloudflareClient.CloudflareZone`. Zone tokens are stored securely in Keychain (migrated from older UserDefaults). When adding zones, store zone-specific tokens under `apiToken_<zoneId>`.
- **Keychain-first for secrets:** Credentials (accountId, zoneId, apiToken) are persisted via `KeychainHelper`. The client performs migrations from UserDefaults to Keychain on init — preserve migration logic when changing credential handling.
- **Background / startup flow:** On launch, app refreshes domain name, forwarding addresses and optionally subdomains. Background sync and user identifier assignment are implemented in `ghostmailApp` (`updateUserIdentifiers`, `forceSyncExistingData`). Take care to keep these operations non-blocking and error-tolerant.

## Developer workflows & useful commands
- **Build & run:** Open `ghostmail.xcodeproj` in Xcode and run on a simulator or device. No custom build scripts are required.
- **CloudKit / iCloud:** Toggle iCloud sync in app Settings (`iCloudSyncEnabled` AppStorage). The app uses `iCloud.com.sendmebits.ghostmail` container when enabled. To test CloudKit behaviors, disable/enable sync and verify `ModelContainer` initialization logs in console.
- **Credentials for local testing:** Use the app UI to add your Account ID, Zone ID, and API Token. Tokens require permissions documented in the README (Email Routing read and Zone edit). Tokens are verified via `verifyToken()` (user token first, then account token fallback).
- **CSV import:** The UI supports CSV import (see `README.md`). The importer infers zone from the email domain and falls back to the primary zone if none match.
- **Debugging tips:** Use the Xcode console logs — `CloudflareClient` logs masked URLs and token verification steps. The app also uses `LogBuffer` for additional runtime logs; inspect it when diagnosing API behavior.

## Project-specific patterns (do not deviate)
- **Filters are staged:** Filter sheets (e.g., `EmailListView`) follow a staged selection pattern and require an explicit Apply button. Avoid auto-applying selections.
- **Don't add an AccentColor asset:** The app uses system `.tint()` for UI accents. Prefer `Color` or `.tint(.blue)` over adding an AccentColor asset.
- **Dark-first UI:** The app assumes a dark appearance (`.preferredColorScheme(.dark)`) — verify visual changes in dark mode.
- **API page size & deduplication:** Cloudflare calls fetch pages of 100 items (`per_page=100`) where applicable, and the code deduplicates aliases by email address. Follow this pattern to avoid duplicates and conserve API calls.

## Where to make common changes (examples)
- **Add/edit Cloudflare endpoints:** `ghostmail/Services/CloudflareClient.swift` — keep token handling, pagination, and error mapping consistent with existing functions (e.g., `getEmailRules`, `getEmailRulesAllZones`).
- **Add new SwiftData model fields:** Update `ghostmail/Models/EmailAlias.swift` and ensure migration-friendly defaults; test CloudKit sync if `iCloudSyncEnabled` is true.
- **Add UI screens:** `ghostmail/Views/` — follow existing state patterns (`@State`, `@Binding`, `@EnvironmentObject`) and preserve staged selection interactions.

## Integration & testing notes
- **No unit test targets:** There are no bundled unit tests. Prefer manual UI testing and integration checks against a Cloudflare test account.
- **Token verification & migration safety:** Token verification flow prefers user tokens, then account tokens. Ensure any new verification code keeps the same user-first, account-second approach to avoid changing behavior.

## Key files & directories (quick reference)
- `ghostmail/Services/CloudflareClient.swift` — Cloudflare API + multi-zone logic
- `ghostmail/Services/KeychainHelper.swift` — Keychain storage helpers
- `ghostmail/Services/LogBuffer.swift` — logging helper used across network calls
- `ghostmail/Models/EmailAlias.swift` — SwiftData model for aliases
- `ghostmail/ghostmailApp.swift` — App lifecycle, ModelContainer setup, CloudKit handling
- `ghostmail/Views/` — primary UI implementation

---
## Agent Instructions
When the task requires multiple steps or non-trivial changes, present a detailed plan using #planReview and wait for approval before executing.
If the plan is rejected, incorporate the comments and submit an updated plan with #planReview.
When the user asks for a step-by-step guide or walkthrough, present it using #walkthroughReview.
Always use #askUser before completing any task to confirm the result matches what the user asked for.

