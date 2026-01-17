# Copilot Instructions for Ghost Mail iOS

## Overview
Ghost Mail is a SwiftUI iOS app for managing Cloudflare Email Routing aliases. Supports multi-zone configurations, iCloud sync, email statistics, and SMTP sending.

## Project Structure

### Services (`ghostmail/Services/`)
| File | Purpose |
|------|---------|
| `CloudflareClient.swift` | All Cloudflare API calls, multi-zone support, pagination (100/page) |
| `KeychainHelper.swift` | Secure token storage (`apiToken_<zoneId>`) |
| `StatisticsCache.swift` | 24-hour cache for email analytics |
| `IconCache.swift` | Favicon caching with SVG rasterization |
| `DeepLinkRouter.swift` | `ghostmail://create?url=` deep links |
| `SMTPService.swift` | Email sending via configured SMTP |
| `LogBuffer.swift` | Debug logging buffer |

### Models (`ghostmail/Models/`)
| Model | Key Properties |
|-------|----------------|
| `EmailAlias` | `emailAddress`, `forwardTo`, `actionType`, `zoneId`, `website` |
| `EmailStatistic` | `emailAddress`, `receivedDates`, `emailDetails` |
| `SMTPSettings` | SMTP server configuration |

### Views (`ghostmail/Views/`)
| View | Purpose |
|------|---------|
| `EmailListView` | Main alias list with filtering, search, charts |
| `EmailDetailView` | Alias details, editing, statistics |
| `EmailCreateView` | Create new alias with AI suggestions |
| `SettingsView` | App settings, zone management |
| `ZoneDetailView` | Per-zone settings, catch-all toggle |
| `EmailStatisticsView` | All email statistics overview |
| `EmailTrendChartView` | 7-day bar chart component |
| `DailyEmailsView` / `WeeklyEmailsView` | Statistics drill-down views |
| `EmailStatisticsShared.swift` | Shared types: `EmailLogItem`, `ActionSummaryBadge`, Array extensions |

## Key Patterns

### UI Conventions
- **Typography:** Use `.font(.system(.size, design: .rounded, weight: .weight))`
- **Haptics:** Use `UIImpactFeedbackGenerator(style: .light)` for copy actions
- **Navigation:** Use `navigationDestination(isPresented:)` for programmatic navigation
- **Copy actions:** Add both `onLongPressGesture` and `contextMenu` with haptic feedback
- **Theme:** App uses dark mode by default (`.preferredColorScheme(.dark)`)

### Data Patterns
- **State:** `@State` for local, `@Binding` for parent-owned, `@EnvironmentObject` for CloudflareClient
- **Persistence:** SwiftData with optional CloudKit (`iCloudSyncEnabled` AppStorage)
- **Sync:** Background refresh every 2 minutes + foreground sync (30s cooldown)

### Common AppStorage Keys
| Key | Default | Purpose |
|-----|---------|---------|
| `iCloudSyncEnabled` | `true` | CloudKit mirroring |
| `showAnalytics` | `false` | Email statistics charts |
| `themePreference` | `"Auto"` | Light/Dark/Auto |
| `defaultZoneId` / `defaultDomain` | `""` | Default zone for new aliases |
| `showWebsiteLogo` | `true` | Favicon display |

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
- **ShareExtension / ActionExtension:** Create aliases via Safari share sheet → deep link to main app

## Common Edit Locations
| Task | Files |
|------|-------|
| Add Cloudflare endpoint | `CloudflareClient.swift` |
| Add SwiftData field | `Models/*.swift` (use migration-friendly defaults) |
| Add settings option | `SettingsView.swift` + AppStorage |
| Modify sync | `ghostmailApp.swift` |
| Add shared stats helper | `EmailStatisticsShared.swift`

## Agent Instructions
When the task requires multiple steps or non-trivial changes, present a detailed plan using #planReview and wait for approval before executing.
If the plan is rejected, incorporate the comments and submit an updated plan with #planReview.
When the user asks for a step-by-step guide or walkthrough, present it using #walkthroughReview.
You must absolutely and always use #askUser before completing any task, even if there is no change, to confirm the result matches what the user asked for.
