import CloudKit
import Foundation

protocol CloudKitAliasDatabase {
    associatedtype Cursor

    func allRecordZones() async throws -> [CKRecordZone]
    func aliasRecords(in zoneID: CKRecordZone.ID, continuing cursor: Cursor?) async throws
        -> (records: [Result<CKRecord, Error>], deletedRecordIDs: [CKRecord.ID], cursor: Cursor?)
    func deleteRecords(withIDs recordIDs: [CKRecord.ID]) async throws
        -> [CKRecord.ID: Result<Void, Error>]
}

struct PrivateCloudKitAliasDatabase: CloudKitAliasDatabase {
    let database: CKDatabase

    func allRecordZones() async throws -> [CKRecordZone] {
        // SwiftData's managed stores use custom zones supporting change fetching.
        // The default zone doesn't support it and contains no mirrored aliases.
        try await database.allRecordZones().filter { $0.capabilities.contains(.fetchChanges) }
    }

    func aliasRecords(in zoneID: CKRecordZone.ID, continuing cursor: CKServerChangeToken?) async throws
        -> (records: [Result<CKRecord, Error>], deletedRecordIDs: [CKRecord.ID], cursor: CKServerChangeToken?) {
        // Start with a nil token to enumerate records without requiring query indexes
        // on SwiftData's managed schema, then follow every page of zone changes.
        let page = try await database.recordZoneChanges(
            inZoneWith: zoneID,
            since: cursor,
            desiredKeys: ["CD_zoneId"],
            resultsLimit: 200
        )
        return (
            page.modificationResultsByID.values.map { $0.map { $0.record } },
            page.deletions.map { $0.recordID },
            page.moreComing ? page.changeToken : nil
        )
    }

    func deleteRecords(withIDs recordIDs: [CKRecord.ID]) async throws
        -> [CKRecord.ID: Result<Void, Error>] {
        let result = try await database.modifyRecords(saving: [], deleting: recordIDs, atomically: false)
        return result.deleteResults
    }
}

/// Removes one Cloudflare zone's aliases from shared managed CloudKit record zones.
/// Call only after this device has restarted with CloudKit mirroring disabled.
struct CloudKitAliasDeletionService<Database: CloudKitAliasDatabase> {
    let database: Database

    func deleteAliases(for cloudflareZoneID: String) async throws -> Int {
        let targetZoneID = cloudflareZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetZoneID.isEmpty else {
            throw DeletionError.missingZoneID
        }

        let zones = try await retry { try await database.allRecordZones() }
        var recordIDsByZone: [CKRecordZone.ID: Set<CKRecord.ID>] = [:]

        // Finish scanning before deleting, so the operation sees a complete set.
        for zone in zones {
            var cursor: Database.Cursor?
            repeat {
                let page = try await retry {
                    try await database.aliasRecords(in: zone.zoneID, continuing: cursor)
                }
                for result in page.records {
                    // A per-record fetch failure must not masquerade as a complete scan.
                    let record = try result.get()
                    // A later page can contain a newer version assigned to another
                    // domain; use its latest identity when choosing records to delete.
                    recordIDsByZone[record.recordID.zoneID]?.remove(record.recordID)
                    guard record.recordType == "CD_EmailAlias",
                          let zoneID = record["CD_zoneId"] as? String,
                          zoneID.trimmingCharacters(in: .whitespacesAndNewlines) == targetZoneID else { continue }
                    recordIDsByZone[record.recordID.zoneID, default: []].insert(record.recordID)
                }
                for id in page.deletedRecordIDs {
                    recordIDsByZone[id.zoneID]?.remove(id)
                }
                cursor = page.cursor
            } while cursor != nil
        }

        var deletedCount = 0
        for recordIDs in recordIDsByZone.values {
            let ids = Array(recordIDs)
            for start in stride(from: 0, to: ids.count, by: 200) {
                let batch = Array(ids[start..<min(start + 200, ids.count)])
                try await retry {
                    let results = try await database.deleteRecords(withIDs: batch)
                    for id in batch {
                        guard let result = results[id] else {
                            throw DeletionError.missingDeleteResult
                        }
                        do {
                            try result.get()
                        } catch {
                            // A prior attempt or another device may already have deleted it.
                            guard (error as? CKError)?.code == .unknownItem else { throw error }
                        }
                    }
                }
                deletedCount += batch.count
            }
        }
        return deletedCount
    }

    private func retry<T>(_ operation: () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            do {
                return try await operation()
            } catch {
                guard attempt < 2, let cloudError = error as? CKError,
                      [.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy]
                        .contains(cloudError.code) else { throw error }
                let retryAfter = (error as NSError).userInfo[CKErrorRetryAfterKey] as? NSNumber
                let delay = max(retryAfter?.doubleValue ?? 0, pow(2, Double(attempt)))
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw DeletionError.missingDeleteResult
    }

    enum DeletionError: LocalizedError {
        case missingZoneID
        case missingDeleteResult

        var errorDescription: String? {
            switch self {
            case .missingZoneID:
                return "No domain is selected. Add a domain before deleting its iCloud data."
            case .missingDeleteResult:
                return "iCloud did not confirm every deletion. Some data may remain; please try again."
            }
        }
    }
}
