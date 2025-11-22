# Email Statistics Caching Strategy

## Overview
Implements intelligent caching for email statistics to provide instant chart display on app launch while keeping data fresh.

## Architecture

### StatisticsCache Service
- **Location**: `ghostmail/Services/StatisticsCache.swift`
- **Storage**: UserDefaults (simple, fast, no database overhead)
- **Cache Lifetime**: 24 hours
- **Data Structure**: Codable wrappers for `EmailStatistic` and `EmailDetail`

### Key Features

#### 1. Shared Cache Across Views
- Main list view and individual email detail views share the same cache
- No duplicate data storage
- Consistent data across the app
- Cache updates benefit all views

#### 2. Smart Loading Strategy

**Main List View (`EmailListView`):**
- On launch: Shows cached data instantly if available
- Fresh cache (< 24h): No network call needed
- Stale cache (> 24h): Shows cached data, fetches fresh in background
- No cache: Shows skeleton placeholder while loading
- Manual refresh: Always bypasses cache

**Detail View (`EmailDetailView`):**
- Reuses cache from main list view
- Filters to specific email address
- Updates cache when fetching fresh data
- Merges with existing cache to preserve other zones' data

#### 3. Performance Optimizations

**Efficient Filtering:**
- Stores unfiltered statistics in memory
- `refilterStatistics()` for instant filter/search updates
- No network calls when changing filters

**Cache Merging:**
- When detail view fetches data, it merges with existing cache
- Preserves statistics from other zones
- Benefits both list and detail views

## User Experience

### First Launch
- Shows skeleton placeholder (~2-3 seconds)
- Fetches and caches data
- Subsequent launches are instant

### Same Day Launches
- Chart appears instantly (< 1ms)
- No loading indicators
- No network calls

### Next Day Launch
- Shows previous day's data instantly
- Small spinner indicates background refresh
- Chart updates when fresh data arrives
- Smooth transition, no jarring reloads

### Manual Refresh
- Pull-to-refresh always gets fresh data
- Updates cache for future launches
- Visual feedback during refresh

## Visual Feedback

### Loading States
1. **No cache**: Skeleton placeholder with spinner
2. **Stale cache refreshing**: Chart visible with small spinner in header
3. **Fresh cache**: Chart visible, no loading indicators

### Placeholders
- Skeleton maintains exact chart dimensions
- Prevents layout shifts
- Consistent visual experience

## Benefits

✅ **Fast App Launch**: Charts appear instantly in most cases  
✅ **No Background Operations**: No battery impact, no scheduled tasks  
✅ **Graceful Degradation**: Stale data shown while refreshing  
✅ **Efficient Storage**: Single cache shared across views  
✅ **Smart Updates**: Cache updates benefit all views  
✅ **Simple Maintenance**: Clean, understandable code  

## Cache Management

### Automatic
- Cache updates on every successful fetch
- 24-hour automatic expiration
- Stale data triggers background refresh

### Manual
- Pull-to-refresh bypasses cache
- No user-facing cache clearing needed
- Cache survives app restarts

## Implementation Details

### Cache Keys
- `EmailStatisticsCache`: Encoded statistics data
- `EmailStatisticsCacheTimestamp`: Cache creation time

### API Methods

**StatisticsCache:**
```swift
save(_ statistics: [EmailStatistic])
load() -> (statistics: [EmailStatistic], isStale: Bool)?
loadForEmail(_ emailAddress: String) -> (statistic: EmailStatistic?, isStale: Bool)?
clear()
var isFresh: Bool
```

**EmailListView:**
```swift
loadStatistics(useCache: Bool = true)
refilterStatistics()
```

**EmailDetailView:**
```swift
loadStatistics(useCache: Bool = true)
```

## Future Enhancements

Possible improvements if needed:
- Per-zone cache expiration
- Cache size limits
- Background refresh on app activation (if desired)
- Cache compression for large datasets

## Testing Scenarios

1. **First launch**: Verify skeleton shows, then chart appears
2. **Second launch same day**: Verify instant chart display
3. **Launch next day**: Verify cached chart shows, then updates
4. **Manual refresh**: Verify fresh data fetched
5. **Filter changes**: Verify instant updates without network calls
6. **Navigate to detail**: Verify instant chart display
