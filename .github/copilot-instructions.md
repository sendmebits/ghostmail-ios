# Copilot Instructions for Ghost Mail iOS

## Overview
Ghost Mail is a SwiftUI iOS app for managing Cloudflare Email Routing aliases. It supports multi-zone configurations, iCloud sync, email statistics, and sending emails via SMTP.

## Architecture

### Core Components
| Component | Location | Purpose |
|-----------|----------|---------|
| CloudflareClient | `Services/CloudflareClient.swift` | All Cloudflare API interactions, multi-zone support, pagination |
| SwiftData Models | `Models/` | `EmailAlias`, `EmailStatistic`, `SMTPSettings` |
| KeychainHelper | `Services/KeychainHelper.swift` | Secure credential storage (tokens stored as `apiToken_<zoneId>`) |
| StatisticsCache | `Services/StatisticsCache.swift` | 24-hour cache for email analytics |
| IconCache | `Services/IconCache.swift` | Website favicon caching with SVG rasterization |
| DeepLinkRouter | `Services/DeepLinkRouter.swift` | Handles `ghostmail://create?url=` deep links |

### Data Flow
- **Persistence:** SwiftData with optional CloudKit mirroring (`iCloudSyncEnabled` AppStorage)
- **Sync:** Background refresh every 2 minutes + immediate sync on foreground return (30s cooldown)
- **Startup:** Parallel loading of domain names, forwarding addresses, and subdomains

## Key Patterns

### Do
- Use `@EnvironmentObject` for `CloudflareClient` access in views
- Store secrets in Keychain via `KeychainHelper`
- Use staged filter pattern (pending → apply button) in filter sheets
- Fetch Cloudflare data in pages of 100 (`per_page=100`)
- Deduplicate aliases by email address
- Validate image dimensions before caching (avoid 0-dimension images)
- Test UI changes in dark mode (app uses `.preferredColorScheme(.dark)`)

### Don't
- Add an AccentColor asset (use `.tint()` modifier instead)
- Auto-apply filter selections
- Block the main thread during network calls
- Store tokens in UserDefaults (migrate to Keychain)

## App Extensions
- **ShareExtension:** Creates aliases from Safari share sheet → opens main app via deep link
- **ActionExtension:** Similar flow for action extensions

## Common Changes

| Task | Files to Edit |
|------|---------------|
| Add Cloudflare endpoint | `CloudflareClient.swift` — follow existing pagination/error handling |
| Add SwiftData field | `Models/*.swift` — use migration-friendly defaults |
| Add new view | `Views/` — use `@State`, `@Binding`, `@EnvironmentObject` |
| Modify sync behavior | `ghostmailApp.swift` — see `performForegroundSyncIfNeeded`, `performBackgroundUpdateIfNeeded` |

## Settings & Feature Flags
| AppStorage Key | Default | Purpose |
|----------------|---------|---------|
| `iCloudSyncEnabled` | `true` | CloudKit mirroring |
| `showAnalytics` | `false` | Email statistics charts |
| `themePreference` | `"Auto"` | Light/Dark/Auto theme |
| `shouldShowWebsiteLogos` | varies | Favicon display in list |

## Build & Test
- Open `ghostmail.xcodeproj` in Xcode, run on simulator or device
- No unit tests — manual testing with Cloudflare test account
- CloudKit testing: toggle sync in Settings, watch console logs

---
## Agent Instructions
- Present multi-step plans using `#planReview` before executing
- Present walkthroughs using `#walkthroughReview`
- Always confirm completion with `#askUser`

