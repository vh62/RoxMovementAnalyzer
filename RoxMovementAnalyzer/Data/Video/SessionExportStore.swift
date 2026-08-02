import Foundation
import os

/// Manages the exported session videos kept in the app's Documents directory.
///
/// An overlay export is a full second copy of a recording, so without housekeeping the app would
/// grow by one video per set forever. A copy that has reached the photo library is redundant and
/// is removed; one that has not (photo access declined, or the save failed) is kept so the athlete
/// can still share it.
enum SessionExportStore {
    private static let log = Logger(subsystem: "rox.video", category: "SessionExportStore")

    /// Exports older than this are assumed abandoned — already shared, or left behind by an
    /// interrupted export.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    static let filePrefix = "rox-session-"

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Deletes one export, used once the photo library holds a copy.
    static func removeExport(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone — nothing to do.
        } catch {
            log.error("could not remove export: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes exports older than `retention`. Safe to call on every launch.
    static func pruneStaleExports(now: Date = Date()) {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents where url.lastPathComponent.hasPrefix(filePrefix) {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }

            if now.timeIntervalSince(modified) > retention {
                removeExport(at: url)
            }
        }
    }
}
