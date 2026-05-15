# Agent Instructions for Ghost Mail iOS

## Overview
Ghost Mail is a SwiftUI iOS app for managing Cloudflare Email Routing aliases. Supports multi-zone configurations, sub-domains, iCloud sync, email statistics, and SMTP sending.

## Project Structure

### Services (`ghostmail/Services/`)
| File | Purpose |
|------|---------|
| `CloudflareClient.swift` | All Cloudflare API calls, multi-zone support, pagination (100/page) |
| `KeychainHelper.swift` | Keychain wrapper; tokens stored at service `"ghostmail"` / account `apiToken_<zoneId>` (per-zone), with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so secrets are not iCloud-backed |
| `StatisticsCache.swift` | 24-hour cache for email analytics |
| `IconCache.swift` | Favicon caching (raster formats only; SVG favicons are intentionally ignored) |
| `DeepLinkRouter.swift` | `ghostmail://create?url=` deep links |
| `SMTPService.swift` | Email sending via configured SMTP |
| `LogBuffer.swift` | Debug logging buffer |
| `AppDelegate.swift` / `SceneDelegate.swift` | UIKit lifecycle hooks (deep link handling, scene config) |

### Models (`ghostmail/Models/`)
| Model | Key Properties |
|-------|----------------|
| `EmailAlias` | `emailAddress`, `forwardTo`, `actionType`, `zoneId`, `website` |
| `EmailStatistic` | `emailAddress`, `receivedDates`, `emailDetails` |
| `SMTPSettings` | SMTP server configuration |

### Views (`ghostmail/Views/`)
| View | Purpose |
|------|---------|
| `ContentView` | Root view; switches between `AuthenticationView` and `EmailListView` |
| `AuthenticationView` | Initial credential entry / onboarding |
| `EmailListView` | Main alias list with filtering, search, charts |
| `EmailDetailView` | Alias details, editing, statistics |
| `EmailCreateView` | Create new alias; offers Apple Intelligence (FoundationModels) generation when available |
| `EmailComposeView` | Send mail via configured SMTP |
| `SettingsView` / `SMTPSettingsView` | App settings, SMTP config, zone management |
| `AddZoneView` / `ZoneDetailView` / `ZoneTokenSheets` | Zone onboarding, per-zone settings (catch-all toggle), token entry |
| `EmailStatisticsView` / `EmailStatisticsDetailView` | Statistics overview + drill-down |
| `EmailTrendChartView` | 7-day bar chart component |
| `DailyEmailsView` / `WeeklyEmailsView` | Statistics drill-down by day/week |
| `EmailStatisticsShared.swift` | Shared types: `EmailLogItem`, `ActionSummaryBadge`, `Array where Element == EmailAlias` lookup extension |

## Key Patterns

### UI Conventions
- **Typography:** Use `.font(.system(.<textStyle>, design: .rounded, weight: .<weight>))` (e.g. `.font(.system(.title3, design: .rounded, weight: .bold))`)
- **Haptics:** `UIImpactFeedbackGenerator(style: .light)` for copy/tap; `.medium`/`.heavy` for destructive or primary confirmations
- **Navigation:** Use `navigationDestination(isPresented:)` for programmatic navigation
- **Copy actions:** Add both `onLongPressGesture` and `contextMenu` with haptic feedback
- **Theme:** Respect the user's `themePreference` AppStorage setting (default `"Auto"`) and apply `.preferredColorScheme(themeColorScheme)` (uses system appearance when `Auto`).

### Data Patterns
- **State:** `@State` for local, `@Binding` for parent-owned, `@EnvironmentObject` for CloudflareClient
- **Persistence:** SwiftData with optional CloudKit (`iCloudSyncEnabled` AppStorage)
- **Sync:** `ghostmailApp.swift` runs a 60s timer that triggers a background refresh once the 120s `updateInterval` has elapsed; foreground returns use a 30s cooldown

### Common AppStorage Keys
| Key | Default | Purpose |
|-----|---------|---------|
| `iCloudSyncEnabled` | `true` | CloudKit mirroring |
| `showAnalytics` | `false` | Email statistics charts |
| `themePreference` | `"Auto"` | Light/Dark/Auto |
| `defaultZoneId` / `defaultDomain` | `""` | Default zone for new aliases |
| `showWebsiteLogo` | `true` | Favicon display |
| `showWebsitesInList` | `true` | Show website under each row in list |

## Do / Don't

### Do
- Store tokens in Keychain via `KeychainHelper`
- Use staged filter pattern (pending → apply button) in sheets
- Fetch Cloudflare data with `per_page=100`
- Add haptic feedback to all copy/paste actions
- Use `EmailStatisticsShared.swift` extensions for alias lookups

### Don't
- Add AccentColor asset (use `.tint()` modifier)
- Auto-apply filter selections
- Block main thread with network calls
- Store tokens in UserDefaults
- Duplicate code already in `EmailStatisticsShared.swift`

## App Extensions
- **GhostMailShareExtension** (`GhostMailShareExtension/ShareViewController.swift`): receives a URL from the iOS share sheet and opens the main app via the `ghostmail://create?url=…` deep link (handled by `DeepLinkRouter`).

## Common Edit Locations
| Task | Files |
|------|-------|
| Add Cloudflare endpoint | `CloudflareClient.swift` |
| Add SwiftData field | `Models/*.swift` (use migration-friendly defaults) |
| Add settings option | `SettingsView.swift` + AppStorage |
| Modify sync | `ghostmailApp.swift` |
| Add shared stats helper | `EmailStatisticsShared.swift`
