# Copilot Instructions for Ghost Mail iOS

## Project Overview
**Ghost Mail** is a SwiftUI iOS app for managing Cloudflare email aliases. It is fully open-source, privacy-focused, and designed for quick creation, disabling, and deletion of disposable email addresses for Cloudflare-hosted domains. No paywalls, tracking, or proprietary lock-in.

## Architecture & Key Components
- **SwiftUI-first:** All UI is in SwiftUI. Main views are in `ghostmail/Views/` (e.g., `EmailListView.swift`, `EmailCreateView.swift`, `SettingsView.swift`).
- **Cloudflare API Integration:** All network logic is in `ghostmail/Services/CloudflareClient.swift`, which handles fetching, creating, updating, and deleting aliases via Cloudflare's Email Routing API. This is the single source of truth for Cloudflare operations.
- **Models:** Data models (e.g., `EmailAlias.swift`) are in `ghostmail/Models/`.
- **State Management:** Uses `@State`, `@Binding`, and `@EnvironmentObject`. The `CloudflareClient` is injected as an environment object for shared data and API access.
- **Persistence:** Uses SwiftData (or Core Data) for local alias storage and sync. User preferences (sort/filter) are stored in `UserDefaults` (e.g., `EmailListView.sortOrder`).
- **Assets:** App icons and images are in `ghostmail/Assets.xcassets/`.

## Developer Workflows
- **Build/Run:** Open `ghostmail.xcodeproj` in Xcode and build for iOS Simulator or device. No custom scripts required.
- **Testing:** No explicit test targets; manual UI testing is expected.
- **Debugging:** Use Xcode's debugger. API/network errors are surfaced as alerts in the UI.
- **CSV Import:** Bulk alias creation is supported via CSV import. See [README.md](../README.md) for format:
	```
	Email Address,Website,Notes,Created,Enabled,Forward To
	user@domain.com,website.com[optional],notes[optional],2025-02-07T01:39:10Z[optional],true,forwardto@domain.com
	```

## Project-Specific Patterns & Conventions
- **Filter Sheets:** Filters (e.g., in `EmailListView`) use staged selection with an explicit Apply button. Do not auto-apply on tap.
- **Cloudflare Zones:** The app supports multiple Cloudflare zones (domains). Filtering and alias creation are zone-aware.
- **No AccentColor Asset:** Use system tints (e.g., `.tint(.blue)`) for buttons; do not add a custom AccentColor asset.
- **Dark Mode:** The app defaults to `.preferredColorScheme(.dark)` and uses dark backgrounds.

## Integration & External Dependencies
- **Cloudflare API:** All network operations are via Cloudflare's Email Routing API. See `CloudflareClient.swift` for endpoints and authentication.
- **No 3rd-party Swift packages** are required for core functionality.

## Examples & Patterns
- **Adding a new filter:** Follow the staged selection pattern in `EmailListView.swift`.
- **Adding a Cloudflare operation:** Implement in `CloudflareClient.swift` and expose via `@EnvironmentObject`.
- **UI changes:** Use SwiftUI and prefer state-driven updates.

## Key Files/Directories
- `ghostmail/Views/` — SwiftUI views
- `ghostmail/Services/CloudflareClient.swift` — Cloudflare API logic
- `ghostmail/Models/EmailAlias.swift` — Alias data model
- `ghostmail/Assets.xcassets/` — App icons and images
- `ghostmail.xcodeproj/` — Xcode project

---

For more, see the [README.md](../README.md). If a convention or workflow is unclear, check the relevant file or ask for clarification.
