import Foundation

// Notification posted when statistics cache is updated
extension Notification.Name {
    static let statisticsCacheUpdated = Notification.Name("statisticsCacheUpdated")
}

/// Simple cache for email statistics to improve app launch performance
///
/// Caching Strategy:
/// - Statistics are cached in UserDefaults with a timestamp
/// - Cache is considered "fresh" for 24 hours
/// - On app launch, cached data is shown immediately if available
/// - If cache is stale (>24 hours), it's still shown but fresh data is fetched in background
/// - Manual refresh always bypasses cache to get latest data
/// - No background operations or scheduled updates needed
class StatisticsCache {
    static let shared = StatisticsCache()
    
    private let cacheKey = "EmailStatisticsCache"
    private let timestampKey = "EmailStatisticsCacheTimestamp"
    private let maxCacheAge: TimeInterval = 24 * 60 * 60 // 24 hours
    
    private init() {}
    
    /// Save statistics to cache with current timestamp
    func save(_ statistics: [EmailStatistic]) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(statistics.map { CachedStatistic(from: $0) })
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: timestampKey)
            
            // Post notification to inform listeners that cache has been updated
            NotificationCenter.default.post(name: .statisticsCacheUpdated, object: nil)
        } catch {
            print("Failed to cache statistics: \(error)")
        }
    }
    
    /// Load cached statistics if available and not stale
    func load() -> (statistics: [EmailStatistic], isStale: Bool)? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let timestamp = UserDefaults.standard.object(forKey: timestampKey) as? Date else {
            return nil
        }
        
        do {
            let decoder = JSONDecoder()
            let cached = try decoder.decode([CachedStatistic].self, from: data)
            let statistics = cached.map { $0.toEmailStatistic() }
            
            let age = Date().timeIntervalSince(timestamp)
            let isStale = age > maxCacheAge
            
            return (statistics, isStale)
        } catch {
            print("Failed to load cached statistics: \(error)")
            return nil
        }
    }
    
    /// Clear the cache
    func clear() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: timestampKey)
    }
    
    /// Check if cache exists and is fresh (< 24 hours old)
    var isFresh: Bool {
        guard let timestamp = UserDefaults.standard.object(forKey: timestampKey) as? Date else {
            return false
        }
        let age = Date().timeIntervalSince(timestamp)
        return age <= maxCacheAge
    }
    
    /// Get statistics for a specific email address from cache
    func loadForEmail(_ emailAddress: String) -> (statistic: EmailStatistic?, isStale: Bool)? {
        guard let cached = load() else {
            return nil
        }
        
        let statistic = cached.statistics.first { $0.emailAddress == emailAddress }
        return (statistic, cached.isStale)
    }
}

// MARK: - Codable wrapper for EmailStatistic

private struct CachedStatistic: Codable {
    let emailAddress: String
    let count: Int
    let receivedDates: [Date]
    let emailDetails: [CachedEmailDetail]
    
    init(from statistic: EmailStatistic) {
        self.emailAddress = statistic.emailAddress
        self.count = statistic.count
        self.receivedDates = statistic.receivedDates
        self.emailDetails = statistic.emailDetails.map { CachedEmailDetail(from: $0) }
    }
    
    func toEmailStatistic() -> EmailStatistic {
        EmailStatistic(
            emailAddress: emailAddress,
            count: count,
            receivedDates: receivedDates,
            emailDetails: emailDetails.map { $0.toEmailDetail() }
        )
    }
}

private struct CachedEmailDetail: Codable {
    let from: String
    let date: Date
    
    init(from detail: EmailStatistic.EmailDetail) {
        self.from = detail.from
        self.date = detail.date
    }
    
    func toEmailDetail() -> EmailStatistic.EmailDetail {
        EmailStatistic.EmailDetail(from: from, date: date)
    }
}
