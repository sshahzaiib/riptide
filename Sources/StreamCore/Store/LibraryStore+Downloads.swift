import Foundation
import SwiftData

@MainActor
public extension LibraryStore {
    func allDownloads() throws -> [DownloadRecord] {
        try context.fetch(FetchDescriptor<DownloadRecord>())
    }

    func downloadRecord(itemKey: String) throws -> DownloadRecord? {
        var d = FetchDescriptor<DownloadRecord>(
            predicate: #Predicate { $0.itemKey == itemKey })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    func completedDownloads() throws -> [DownloadRecord] {
        try allDownloads().filter { $0.state == .completed }
    }

    func upsertDownload(itemKey: String, localPath: String, state: DownloadState,
                        totalBytes: Int64, downloadedBytes: Int64,
                        title: String, filename: String,
                        errorMessage: String? = nil) throws {
        if let rec = try downloadRecord(itemKey: itemKey) {
            rec.localPath = localPath
            rec.state = state
            rec.totalBytes = totalBytes
            rec.downloadedBytes = downloadedBytes
            rec.title = title
            rec.filename = filename
            rec.errorMessage = errorMessage
        } else {
            context.insert(DownloadRecord(
                itemKey: itemKey, localPath: localPath, state: state,
                totalBytes: totalBytes, downloadedBytes: downloadedBytes,
                title: title, filename: filename, errorMessage: errorMessage))
        }
        try context.save()
    }

    func deleteDownload(itemKey: String) throws {
        if let rec = try downloadRecord(itemKey: itemKey) {
            context.delete(rec)
            try context.save()
        }
    }

    func item(itemKey: String) throws -> LibraryItem? {
        var d = FetchDescriptor<LibraryItem>(
            predicate: #Predicate { $0.itemKey == itemKey })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }
}
