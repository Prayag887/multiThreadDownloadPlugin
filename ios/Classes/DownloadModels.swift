import Foundation

// MARK: - Download Status Enum
enum DownloadStatus: Int, CaseIterable {
    case pending = 0
    case downloading = 1
    case paused = 2
    case completed = 3
    case failed = 4
    case cancelled = 5
    case initializing = 6

    var stringValue: String {
        switch self {
        case .pending: return "pending"
        case .downloading: return "downloading"
        case .paused: return "paused"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .initializing: return "initializing"
        }
    }
}

// MARK: - Download Task Class
class DownloadTask {
    let url: String
    var filePath: String
    let fileName: String
    let headers: [String: String]
    let retryCount: Int
    let timeoutSeconds: Int

    var totalBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var status: DownloadStatus = .pending
    var error: String?
    var startTime: Int64 = 0
    var lastSpeedUpdate: Int64 = 0
    var task: Task<Void, Error>?
    var speedHistory: [Double] = []

    init(
        url: String,
        filePath: String,
        fileName: String,
        headers: [String: String] = [:],
        retryCount: Int = 3,
        timeoutSeconds: Int = 30
    ) {
        self.url = url
        self.filePath = filePath
        self.fileName = fileName
        self.headers = headers
        self.retryCount = retryCount
        self.timeoutSeconds = timeoutSeconds
        self.startTime = Int64(Date().timeIntervalSince1970 * 1000)
    }

    // Convenience computed properties
    var progressPercentage: Double {
        guard totalBytes > 0 else { return 0.0 }
        return (Double(downloadedBytes) / Double(totalBytes)) * 100.0
    }

    var averageSpeed: Double {
        guard !speedHistory.isEmpty else { return 0.0 }
        return speedHistory.reduce(0, +) / Double(speedHistory.count)
    }

    var elapsedTime: TimeInterval {
        let currentTime = Int64(Date().timeIntervalSince1970 * 1000)
        return TimeInterval(currentTime - startTime) / 1000.0
    }

    // Method to update speed history
    func updateSpeed(_ speed: Double) {
        speedHistory.append(speed)

        // Keep only last 10 speed measurements to prevent memory growth
        if speedHistory.count > 10 {
            speedHistory.removeFirst()
        }

        lastSpeedUpdate = Int64(Date().timeIntervalSince1970 * 1000)
    }

    // Method to reset task for retry
    func reset() {
        downloadedBytes = 0
        status = .pending
        error = nil
        speedHistory.removeAll()
        task?.cancel()
        task = nil
        startTime = Int64(Date().timeIntervalSince1970 * 1000)
    }

    // Convert to dictionary for Flutter communication
    func toDictionary() -> [String: Any] {
        return [
            "url": url,
            "filePath": filePath,
            "fileName": fileName,
            "headers": headers,
            "retryCount": retryCount,
            "timeoutSeconds": timeoutSeconds,
            "totalBytes": totalBytes,
            "downloadedBytes": downloadedBytes,
            "status": status.rawValue,
            "statusString": status.stringValue,
            "error": error ?? "",
            "startTime": startTime,
            "lastSpeedUpdate": lastSpeedUpdate,
            "speedHistory": speedHistory,
            "progress": progressPercentage,
            "averageSpeed": averageSpeed,
            "elapsedTime": elapsedTime
        ]
    }
}

// MARK: - Segment Task Struct
struct SegmentTask {
    let url: String
    let fileName: String
    var size: Int64 = 0
    var downloaded: Bool = false
    var bytes: Int64 = 0
    let duration: Double = 10.0

    init(
        url: String,
        fileName: String,
        size: Int64 = 0,
        downloaded: Bool = false,
        bytes: Int64 = 0,
        duration: Double = 10.0
    ) {
        self.url = url
        self.fileName = fileName
        self.size = size
        self.downloaded = downloaded
        self.bytes = bytes
        self.duration = duration
    }

    // Computed properties
    var progressPercentage: Double {
        guard size > 0 else { return downloaded ? 100.0 : 0.0 }
        return (Double(bytes) / Double(size)) * 100.0
    }

    var isCompleted: Bool {
        return downloaded && (size == 0 || bytes >= size)
    }

    // Convert to dictionary
    func toDictionary() -> [String: Any] {
        return [
            "url": url,
            "fileName": fileName,
            "size": size,
            "downloaded": downloaded,
            "bytes": bytes,
            "duration": duration,
            "progress": progressPercentage,
            "isCompleted": isCompleted
        ]
    }

    // Create from dictionary (useful for parsing from playlists)
    static func fromDictionary(_ dict: [String: Any]) -> SegmentTask? {
        guard let url = dict["url"] as? String,
              let fileName = dict["fileName"] as? String else {
            return nil
        }

        return SegmentTask(
            url: url,
            fileName: fileName,
            size: dict["size"] as? Int64 ?? 0,
            downloaded: dict["downloaded"] as? Bool ?? false,
            bytes: dict["bytes"] as? Int64 ?? 0,
            duration: dict["duration"] as? Double ?? 10.0
        )
    }
}

// MARK: - Variant Playlist Struct
struct VariantPlaylist {
    let url: String
    let fileName: String
    let bandwidth: Int64
    let resolution: String

    init(
        url: String,
        fileName: String,
        bandwidth: Int64 = 0,
        resolution: String = ""
    ) {
        self.url = url
        self.fileName = fileName
        self.bandwidth = bandwidth
        self.resolution = resolution
    }

    // Computed properties
    var qualityDescription: String {
        if !resolution.isEmpty && bandwidth > 0 {
            return "\(resolution) (\(formatBandwidth(bandwidth)))"
        } else if !resolution.isEmpty {
            return resolution
        } else if bandwidth > 0 {
            return formatBandwidth(bandwidth)
        } else {
            return "Unknown Quality"
        }
    }

    private func formatBandwidth(_ bandwidth: Int64) -> String {
        if bandwidth >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000.0)
        } else if bandwidth >= 1_000 {
            return String(format: "%.0f Kbps", Double(bandwidth) / 1_000.0)
        } else {
            return "\(bandwidth) bps"
        }
    }

    // Convert to dictionary
    func toDictionary() -> [String: Any] {
        return [
            "url": url,
            "fileName": fileName,
            "bandwidth": bandwidth,
            "resolution": resolution,
            "qualityDescription": qualityDescription
        ]
    }

    // Create from dictionary (useful for parsing M3U8 playlists)
    static func fromDictionary(_ dict: [String: Any]) -> VariantPlaylist? {
        guard let url = dict["url"] as? String,
              let fileName = dict["fileName"] as? String else {
            return nil
        }

        return VariantPlaylist(
            url: url,
            fileName: fileName,
            bandwidth: dict["bandwidth"] as? Int64 ?? 0,
            resolution: dict["resolution"] as? String ?? ""
        )
    }

    // Parse from M3U8 EXT-X-STREAM-INF line
    static func fromM3U8Line(_ line: String, url: String, fileName: String) -> VariantPlaylist {
        var bandwidth: Int64 = 0
        var resolution = ""

        // Parse BANDWIDTH
        if let bandwidthRange = line.range(of: "BANDWIDTH=") {
            let afterBandwidth = line[bandwidthRange.upperBound...]
            if let commaRange = afterBandwidth.range(of: ",") {
                let bandwidthString = String(afterBandwidth[..<commaRange.lowerBound])
                bandwidth = Int64(bandwidthString) ?? 0
            } else {
                // BANDWIDTH might be the last parameter
                let bandwidthString = String(afterBandwidth)
                bandwidth = Int64(bandwidthString) ?? 0
            }
        }

        // Parse RESOLUTION
        if let resolutionRange = line.range(of: "RESOLUTION=") {
            let afterResolution = line[resolutionRange.upperBound...]
            if let commaRange = afterResolution.range(of: ",") {
                resolution = String(afterResolution[..<commaRange.lowerBound])
            } else {
                // RESOLUTION might be the last parameter
                resolution = String(afterResolution)
            }
        }

        return VariantPlaylist(
            url: url,
            fileName: fileName,
            bandwidth: bandwidth,
            resolution: resolution
        )
    }
}

// MARK: - Download Batch Info
struct DownloadBatchInfo {
    let batchId: String
    let urls: [String]
    let basePath: String
    let headers: [String: String]
    let maxConcurrentTasks: Int
    let retryCount: Int
    let timeoutSeconds: Int
    let createdAt: Date

    init(
        urls: [String],
        basePath: String,
        headers: [String: String] = [:],
        maxConcurrentTasks: Int = 50,
        retryCount: Int = 3,
        timeoutSeconds: Int = 30
    ) {
        self.batchId = UUID().uuidString
        self.urls = urls
        self.basePath = basePath
        self.headers = headers
        self.maxConcurrentTasks = maxConcurrentTasks
        self.retryCount = retryCount
        self.timeoutSeconds = timeoutSeconds
        self.createdAt = Date()
    }

    func toDictionary() -> [String: Any] {
        return [
            "batchId": batchId,
            "urls": urls,
            "basePath": basePath,
            "headers": headers,
            "maxConcurrentTasks": maxConcurrentTasks,
            "retryCount": retryCount,
            "timeoutSeconds": timeoutSeconds,
            "createdAt": Int64(createdAt.timeIntervalSince1970 * 1000)
        ]
    }
}

// MARK: - Download Progress Info
struct DownloadProgressInfo {
    let url: String
    let fileName: String
    let progress: Double
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let status: DownloadStatus
    let speed: Double
    let estimatedTimeRemaining: TimeInterval?
    let error: String?

    init(from task: DownloadTask) {
        self.url = task.url
        self.fileName = task.fileName
        self.progress = task.progressPercentage
        self.bytesDownloaded = task.downloadedBytes
        self.totalBytes = task.totalBytes
        self.status = task.status
        self.speed = task.averageSpeed
        self.error = task.error

        // Calculate estimated time remaining
        if task.averageSpeed > 0 && task.totalBytes > task.downloadedBytes {
            let remainingBytes = task.totalBytes - task.downloadedBytes
            self.estimatedTimeRemaining = Double(remainingBytes) / task.averageSpeed
        } else {
            self.estimatedTimeRemaining = nil
        }
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "url": url,
            "fileName": fileName,
            "progress": progress,
            "bytesDownloaded": bytesDownloaded,
            "totalBytes": totalBytes,
            "status": status.rawValue,
            "statusString": status.stringValue,
            "speed": speed,
            "error": error ?? ""
        ]

        if let eta = estimatedTimeRemaining {
            dict["estimatedTimeRemaining"] = eta
        }

        return dict
    }
}