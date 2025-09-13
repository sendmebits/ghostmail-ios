# Copilot Instructions for Ghost Mail iOS

## Project Overview
- **Ghost Mail** is a SwiftUI iOS app for managing Cloudflare email aliases. It enables users to create, disable, and delete disposable email addresses for domains hosted on Cloudflare.
- The app is 100% open-source and designed for privacy, with no paywalls or tracking.

## Architecture & Key Components
- **SwiftUI-first:** All UI is built with SwiftUI. Major views are in `ghostmail/Views/` (e.g., `EmailListView.swift`, `EmailCreateView.swift`, `SettingsView.swift`).
- **Cloudflare Integration:** API logic is in `ghostmail/Services/CloudflareClient.swift`. This handles fetching, creating, and updating aliases via Cloudflare's API.
- **Models:** Data models (e.g., `EmailAlias.swift`) are in `ghostmail/Models/`.
- **State Management:** Uses `@State`, `@Binding`, and `@EnvironmentObject` for view state. Cloudflare data is shared via `CloudflareClient` as an environment object.
- **Persistence:** Uses SwiftData (or Core Data) for local alias storage and sync.
- **Assets:** App icons and images are in `ghostmail/Assets.xcassets/`.

## Developer Workflows
- **Build:** Open `ghostmail.xcodeproj` in Xcode and build for iOS Simulator or device.
- **Run:** No special scripts; use Xcode's standard Run/Build.
- **Test:** No explicit test targets found; manual testing via the UI is expected.
- **Debug:** Use Xcode's debugger. Network/API issues are surfaced via error alerts in the UI.
- **CSV Import:** Bulk alias creation is supported via CSV import (see README for format).

## Project-Specific Patterns & Conventions
- **Filter Sheets:** Filters (e.g., in `EmailListView`) use staged selection with an explicit Apply button. Do not auto-apply on tap.
- **Cloudflare Zones:** The app supports multiple Cloudflare zones (domains). Filtering and alias creation are zone-aware.
- **Persistence:** User preferences (sort/filter) are stored in `UserDefaults` with keys like `EmailListView.sortOrder`.
- **No AccentColor Asset:** The project does not require a custom AccentColor asset; use system tints (e.g., `.tint(.blue)`) for buttons.
- **Dark Mode:** The app defaults to `.preferredColorScheme(.dark)` and uses dark backgrounds.

## Integration & External Dependencies
- **Cloudflare API:** All network operations are via Cloudflare's Email Routing API. See `CloudflareClient.swift` for endpoints and auth.
- **No 3rd-party Swift packages** are required for core functionality.

## Examples
- **Adding a new filter:** Follow the staged selection pattern in `EmailListView.swift`.
- **Adding a new Cloudflare operation:** Implement in `CloudflareClient.swift` and expose via `@EnvironmentObject`.
- **UI changes:** Use SwiftUI and prefer state-driven updates.

## Key Files/Directories
- `ghostmail/Views/` — All SwiftUI views
- `ghostmail/Services/CloudflareClient.swift` — Cloudflare API logic
- `ghostmail/Models/EmailAlias.swift` — Alias data model
- `ghostmail/Assets.xcassets/` — App icons and images
- `ghostmail.xcodeproj/` — Xcode project

---

For more, see the [README.md](../README.md). If a convention or workflow is unclear, check the relevant file or ask for clarification.
