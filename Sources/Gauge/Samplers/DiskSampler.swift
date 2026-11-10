import Foundation
import IOKit

struct DiskReading {
    var read = 0.0 // bytes/s
    var write = 0.0
    var readSinceBoot: UInt64 = 0
    var writtenSinceBoot: UInt64 = 0
}

struct Volume: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let total: Int64
    let available: Int64
    let isInternal: Bool
    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// Throughput from the block storage drivers' cumulative byte counters.
final class DiskSampler {
    private var previous: (read: UInt64, write: UInt64, time: TimeInterval)?

    func sample() -> DiskReading {
        var read: UInt64 = 0, write: UInt64 = 0
        SysInfo.forEachService("IOBlockStorageDriver") { s in
            guard let stats = SysInfo.property(s, "Statistics") as? [String: Any] else { return }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        let now = ProcessInfo.processInfo.systemUptime
        var r = DiskReading(readSinceBoot: read, writtenSinceBoot: write)
        // A disk that goes away lowers the sums; skip that sample instead of reporting a negative rate.
        if let p = previous, now > p.time, read >= p.read, write >= p.write {
            r.read = Double(read - p.read) / (now - p.time)
            r.write = Double(write - p.write) / (now - p.time)
        }
        previous = (read, write, now)
        return r
    }

    static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
                                      .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            return Volume(path: url.path, name: v.volumeName ?? url.lastPathComponent, total: Int64(total),
                          available: v.volumeAvailableCapacityForImportantUsage ?? 0,
                          isInternal: v.volumeIsInternal ?? false)
        }
        .sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }
}
